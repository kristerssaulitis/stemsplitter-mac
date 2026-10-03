"""Convert KimberleyJSN Mel-Band RoFormer (vocals, MIT weights) to a Core ML program.

Model: 228M params, dim 384, depth 6 (time+freq transformer per block), 60 mel bands,
stereo, num_stems 1 (vocals; instrumental = mix - vocals), STFT 2048/441/2048 unnormalized.
Config from ZFTurbo/Music-Source-Separation-Training configs/KimberleyJensen (MIT), which
ships the yaml for this exact checkpoint. Implementation vendored in tools/msst (MIT).

STFT/iSTFT/scatter are not in the model: Core ML has no complex tensors and no mel-band
scatter. The app does them in Swift (vDSP). The wrapper takes what MelBandRoformer.forward
computes right after torch.stft, and returns the per-band complex masks right before the
scatter/average/multiply/istft.

  inputs : spec (1, 4, 1025, 801)       CaC spectrogram [L.re, L.im, R.re, R.im], T = L//441 + 1
  outputs: mask (1, 2, 3958, 801)       complex mask per band-freq-channel entry, planes [re, im]
  final  : mask[freq,ch] = mean(entries); spec' = mask × spec; bin 0 zeroed; iSTFT

Usage: .venv/bin/python convert_melband.py [--precision mixed|fp16|fp32]

Precision (mask-plane SNR vs fp32 torch is printed; Swift parity test gates at 35 dB):
  mixed : fp16 conv+matmul only (like htdemucs default)
  fp16  : everything fp16, same size
  fp32  : reference, 2x size
Also writes ../Models/reference/melband-roformer-{mix,spec,full}.f32
(mix = 352800-sample stereo input, spec = CaC planes, full = torch end-to-end vocals)
for the Swift parity tests, and embeds freq_indices/bands_per_freq as base64 metadata.
"""
import argparse, base64, pathlib, sys
import numpy as np
import torch
import coremltools as ct

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "msst"))
from mel_band_roformer import MelBandRoformer
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.frontend.torch import ops as ct_ops
from coremltools.converters.mil.frontend.torch.torch_op_registry import register_torch_op


# coremltools 8.3: int() on a shape-(1,) constant crashes. Squeeze it first. (Same fix as
# convert_htdemucs.py; the shape math in Attend/RotaryEmbedding triggers it here too.)
@register_torch_op(override=True)
def int(context, node):
    x = ct_ops._get_inputs(context, node, expected=1)[0]
    if x.val is not None:
        context.add(mb.const(val=np.int32(np.asarray(x.val).reshape(-1)[0]), name=node.name))
    else:
        context.add(mb.cast(x=x, dtype="int32", name=node.name))
# config_vocals_mel_band_roformer_kj.yaml, minus training-loss knobs. flash_attn forced
# off: the CPU einsum+softmax path traces cleanly, F.scaled_dot_product_attention does not.
KW = dict(dim=384, depth=6, stereo=True, num_stems=1, time_transformer_depth=1,
          freq_transformer_depth=1, num_bands=60, dim_head=64, heads=8, flash_attn=False,
          dim_freqs_in=1025, sample_rate=44100, stft_n_fft=2048, stft_hop_length=441,
          stft_win_length=2048, stft_normalized=False, mask_estimator_depth=2)

SR, L, HOP, NFFT = 44100, 352800, 441, 2048
FREQS = NFFT // 2 + 1  # 1025
T = L // HOP + 1       # 801 (torch.stft center=True)

ap = argparse.ArgumentParser()
ap.add_argument("--precision", choices=["mixed", "fp16", "fp32"], default="mixed")
args = ap.parse_args()

out_dir = pathlib.Path(__file__).resolve().parent.parent / "Models"
out_dir.mkdir(exist_ok=True)

net = MelBandRoformer(**KW)
sd = torch.load(pathlib.Path(__file__).resolve().parent / "MelBandRoformer.ckpt",
                map_location="cpu", weights_only=True)
net.load_state_dict(sd, strict=True)
net.eval()
E = net.freq_indices.shape[0]
print(f"params {sum(p.numel() for p in net.parameters())/1e6:.1f}M, entries {E}, frames {T}")


class Core(torch.nn.Module):
    """Everything between torch.stft and the band scatter."""

    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, spec):
        m = self.m
        b, four, f, t = spec.shape
        # spec planes [L.re, L.im, R.re, R.im] -> stft_repr (b, (f s), t, c), f-major.
        stft_repr = spec.reshape(b, 2, 2, f, t).permute(0, 3, 1, 4, 2).reshape(b, f * 2, t, 2)
        x = stft_repr[:, m.freq_indices]                       # (b, E, t, 2)
        x = x.permute(0, 2, 1, 3).reshape(b, t, -1)            # b f t c -> b t (f c)
        x = m.band_split(x)                                    # (b, t, bands, dim)
        for time_t, freq_t in m.layers:
            x = x.permute(0, 2, 1, 3)                          # b f t d
            bf, f2, t2, d = x.shape
            x = time_t(x.reshape(bf * f2, t2, d)).reshape(bf, f2, t2, d)
            x = x.permute(0, 2, 1, 3)                          # b t f d
            bt, t2, f2, d = x.shape
            x = freq_t(x.reshape(bt * t2, f2, d)).reshape(bt, t2, f2, d)
        (est,) = m.mask_estimators                             # num_stems == 1
        masks = est(x)                                         # (b, t, E*2), entry-major re/im
        masks = masks.reshape(b, t, E, 2).permute(0, 2, 1, 3)  # (b, E, t, 2)
        return torch.stack([masks[..., 0], masks[..., 1]], dim=1)  # (b, 2, E, t)


def spec_planes(mix):
    """Swift's input: torch.stft(center=True, reflect) of both channels as CaC planes."""
    z = torch.stft(mix[0], NFFT, HOP, win_length=NFFT, window=torch.hann_window(NFFT),
                   center=True, pad_mode="reflect", return_complex=True)  # (2, f, t)
    return torch.stack([z.real[0], z.imag[0], z.real[1], z.imag[1]])[None]  # (1, 4, f, t)


def external_vocals(mask, spec, net):
    """Python rehearsal of the Swift path, in double precision: scatter-average the band
    masks, complex-multiply the mix spec, zero DC, iSTFT. Must equal net(mix) exactly."""
    entries = torch.complex(mask[0, 0].double(), mask[0, 1].double())       # (E, T)
    grid = torch.zeros(FREQS * 2, T, dtype=torch.complex128)
    grid.index_add_(0, net.freq_indices.long(), entries)
    denom = net.num_bands_per_freq.double().repeat_interleave(2)[:, None]   # j = f*2+s -> bpf[f]
    grid = grid / denom
    z = torch.view_as_complex(torch.stack([spec[0, 0::2], spec[0, 1::2]], dim=-1).double())  # (2, f, t)
    z_grid = z.permute(1, 0, 2).reshape(FREQS * 2, T)
    masked = (grid * z_grid).reshape(FREQS, 2, T).permute(1, 0, 2)          # (2, f, t)
    masked[:, 0] = 0
    return torch.istft(masked, NFFT, HOP, win_length=NFFT,
                       window=torch.hann_window(NFFT), length=L)            # (2, L)


torch.manual_seed(0)
t = torch.arange(L) / SR
mono = 0.3 * torch.sin(2 * torch.pi * 220 * t) + 0.2 * torch.sin(2 * torch.pi * 55 * t) + 0.05 * torch.randn(L)
mix = torch.stack([mono, 0.8 * mono + 0.02 * torch.randn(L)])[None].float()
spec = spec_planes(mix)
assert spec.shape == (1, 4, FREQS, T), spec.shape

core = Core(net).eval()
with torch.no_grad():
    full = net(mix)[0]                    # (2, L) end-to-end torch
    ref_mask = core(spec)                 # (1, 2, E, T)
    ext = external_vocals(ref_mask, spec, net)
snr = lambda a, b: 10 * torch.log10((a ** 2).sum() / ((a - b) ** 2).sum()).item()
print(f"external reconstruction vs torch: SNR {snr(full, ext):.1f} dB (must be huge)")

traced = torch.jit.trace(core, spec, check_trace=False)

mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="spec", shape=spec.shape)],
    outputs=[ct.TensorType(name="mask")],
    minimum_deployment_target=ct.target.macOS15,
    compute_precision={
        "fp32": ct.precision.FLOAT32,
        "fp16": ct.precision.FLOAT16,
        "mixed": ct.transform.FP16ComputePrecision(op_selector=lambda op: op.op_type in ("conv", "conv_transpose", "matmul", "linear")),
    }[args.precision],
)
mlmodel.short_description = "Mel-Band RoFormer vocals core (no STFT/scatter). KimberleyJSN, dim384 depth6 60 bands"
mlmodel.user_defined_metadata["sources"] = "vocals"
mlmodel.user_defined_metadata["segment_samples"] = str(L)
mlmodel.user_defined_metadata["stft_nfft"] = str(NFFT)
mlmodel.user_defined_metadata["stft_hop"] = str(HOP)
mlmodel.user_defined_metadata["stft_bins"] = str(FREQS)
mlmodel.user_defined_metadata["frames"] = str(T)
mlmodel.user_defined_metadata["entries"] = str(E)
mlmodel.user_defined_metadata["freq_indices_b64"] = base64.b64encode(net.freq_indices.numpy().astype("<i4").tobytes()).decode()
mlmodel.user_defined_metadata["bands_per_freq_b64"] = base64.b64encode(net.num_bands_per_freq.numpy().astype("<f4").tobytes()).decode()
mlmodel.user_defined_metadata["license"] = "MIT (KimberleyJSN/melbandroformer weights; ZFTurbo implementation)"
path = out_dir / "melband-roformer.mlpackage"
mlmodel.save(str(path))

pred = mlmodel.predict({"spec": spec.numpy()})
got = torch.from_numpy(pred["mask"])
err = (got.float() - ref_mask).pow(2).sum().item()
print(f"mask: shape={tuple(got.shape)} SNR={snr(ref_mask, got.float()):.1f} dB")
print("saved", path)

ref_dir = out_dir / "reference"
ref_dir.mkdir(exist_ok=True)
for name, arr in (("mix", mix[0]), ("spec", spec[0]), ("full", full)):
    arr.numpy().astype("<f4").tofile(ref_dir / f"melband-roformer-{name}.f32")
