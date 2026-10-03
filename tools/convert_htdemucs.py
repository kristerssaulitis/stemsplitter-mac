"""Convert htdemucs (MIT weights) to a Core ML program.

STFT/iSTFT are not in the model: Core ML has no complex tensors. The app does
them in Swift (vDSP). The wrapper takes exactly what HTDemucs.forward computes
right after `_magnitude`, and returns what it has right before `_mask`/`_ispec`.

  inputs : mix  (1, 2, L)            stereo waveform, L = 343980 (7.8 s @ 44.1k)
           spec (1, 4, 2048, T)      CaC spectrogram: [L.re, L.im, R.re, R.im], T = ceil(L/1024)
  outputs: freq (1, S*4, 2048, T)    per-source CaC spectrogram (denormalized)
           time (1, S*2, L)          per-source time-branch waveform (denormalized)
  final  : source = istft(freq) + time

Usage: .venv/bin/python convert_htdemucs.py [--model htdemucs] [--precision mixed|fp16|fp32]

Precision (measured on real music, per-source SNR vs fp32 torch, M3 Max GPU ms per 7.8 s segment):
  fp16  : 111 ms, drums 27 / bass 23 / other 60 / vocals 63 dB  (bass+drums: freq and time branches
          partly cancel, which amplifies fp16 error)
  mixed : 130 ms, drums 32 / bass 30 / other 63 / vocals 67 dB  (fp16 conv+matmul only, 120 MB) ← default
  fp32  : 248 ms, all > 85 dB, 2x size
Writes ../Models/<model>.mlpackage and ../Models/reference/<model>-{mix,spec,full}.f32
(a 7.8 s input + torch outputs, used by the Swift parity test).
"""
import argparse, math, pathlib
import numpy as np
import torch
import coremltools as ct
from demucs.pretrained import get_model
from demucs.spec import spectro
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.frontend.torch import ops as ct_ops
from coremltools.converters.mil.frontend.torch.torch_op_registry import register_torch_op


# coremltools 8.3: int() on a shape-(1,) constant crashes. Squeeze it first.
@register_torch_op(override=True)
def int(context, node):
    x = ct_ops._get_inputs(context, node, expected=1)[0]
    if x.val is not None:
        context.add(mb.const(val=np.int32(np.asarray(x.val).reshape(-1)[0]), name=node.name))
    else:
        context.add(mb.cast(x=x, dtype="int32", name=node.name))

ap = argparse.ArgumentParser()
ap.add_argument("--model", default="htdemucs")
ap.add_argument("--precision", choices=["mixed", "fp16", "fp32"], default="mixed")
args = ap.parse_args()

out_dir = pathlib.Path(__file__).resolve().parent.parent / "Models"
out_dir.mkdir(exist_ok=True)

bag = get_model(args.model)
net = bag.models[0].eval()  # htdemucs / htdemucs_6s are single-model bags
SR = net.samplerate
L = round(float(net.segment) * SR)
T = math.ceil(L / net.hop_length)
S = len(net.sources)
print(f"{args.model}: sources={net.sources} L={L} T={T}")


class Core(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, mix, spec):
        m = self.m
        x = spec
        B, C, Fq, Tt = x.shape
        mean = x.mean(dim=(1, 2, 3), keepdim=True)
        std = x.std(dim=(1, 2, 3), keepdim=True)
        x = (x - mean) / (1e-5 + std)
        xt = mix
        meant = xt.mean(dim=(1, 2), keepdim=True)
        stdt = xt.std(dim=(1, 2), keepdim=True)
        xt = (xt - meant) / (1e-5 + stdt)

        saved, saved_t, lengths, lengths_t = [], [], [], []
        for idx, encode in enumerate(m.encoder):
            lengths.append(x.shape[-1])
            inject = None
            if idx < len(m.tencoder):
                lengths_t.append(xt.shape[-1])
                tenc = m.tencoder[idx]
                xt = tenc(xt)
                if not tenc.empty:
                    saved_t.append(xt)
                else:
                    inject = xt
            x = encode(x, inject)
            if idx == 0 and m.freq_emb is not None:
                frs = torch.arange(x.shape[-2], device=x.device)
                emb = m.freq_emb(frs).t()[None, :, :, None].expand_as(x)
                x = x + m.freq_emb_scale * emb
            saved.append(x)
        if m.crosstransformer:
            if m.bottom_channels:
                b, c, f, t = x.shape
                x = x.reshape(b, c, f * t)
                x = m.channel_upsampler(x)
                x = x.reshape(b, -1, f, t)
                xt = m.channel_upsampler_t(xt)
            x, xt = m.crosstransformer(x, xt)
            if m.bottom_channels:
                b, c, f, t = x.shape
                x = x.reshape(b, c, f * t)
                x = m.channel_downsampler(x)
                x = x.reshape(b, -1, f, t)
                xt = m.channel_downsampler_t(xt)
        for idx, decode in enumerate(m.decoder):
            skip = saved.pop(-1)
            x, pre = decode(x, skip, lengths.pop(-1))
            offset = m.depth - len(m.tdecoder)
            if idx >= offset:
                tdec = m.tdecoder[idx - offset]
                length_t = lengths_t.pop(-1)
                if tdec.empty:
                    pre = pre[:, :, 0]
                    xt, _ = tdec(pre, None, length_t)
                else:
                    skip = saved_t.pop(-1)
                    xt, _ = tdec(xt, skip, length_t)
        x = x * std + mean
        xt = xt * stdt + meant
        return x, xt


def cac_spec(mix):
    # Same as HTDemucs._spec + _magnitude.
    hl = net.hop_length
    le = math.ceil(mix.shape[-1] / hl)
    pad = hl // 2 * 3
    x = torch.nn.functional.pad(mix, (pad, pad + le * hl - mix.shape[-1]), mode="reflect")
    z = spectro(x, net.nfft, hl)[..., :-1, :][..., 2:2 + le]
    B, C, Fr, Tt = z.shape
    return torch.view_as_real(z).permute(0, 1, 4, 2, 3).reshape(B, C * 2, Fr, Tt)


torch.backends.mha.set_fastpath_enabled(False)  # else traces _native_multi_head_attention
core = Core(net).eval()
torch.manual_seed(0)
# Reference input: a few sines + noise so all sources get some energy.
t = torch.arange(L) / SR
mono = 0.3 * torch.sin(2 * math.pi * 220 * t) + 0.2 * torch.sin(2 * math.pi * 55 * t) + 0.05 * torch.randn(L)
mix = torch.stack([mono, 0.8 * mono + 0.02 * torch.randn(L)])[None].float()
spec = cac_spec(mix)

with torch.no_grad():
    ref_freq, ref_time = core(mix, spec)
    full = net(mix)  # end-to-end torch reference, includes torch istft
    traced = torch.jit.trace(core, (mix, spec), check_trace=False)

mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="mix", shape=mix.shape), ct.TensorType(name="spec", shape=spec.shape)],
    outputs=[ct.TensorType(name="freq"), ct.TensorType(name="time")],
    minimum_deployment_target=ct.target.macOS15,
    compute_precision={
        "fp32": ct.precision.FLOAT32,
        "fp16": ct.precision.FLOAT16,
        # ponytail: op-type granularity. Finer (per-layer) selection may close the last few dB.
        "mixed": ct.transform.FP16ComputePrecision(op_selector=lambda op: op.op_type in ("conv", "conv_transpose", "matmul", "linear")),
    }[args.precision],
)
mlmodel.short_description = f"{args.model} core (no STFT). sources={','.join(net.sources)}"
mlmodel.user_defined_metadata["sources"] = ",".join(net.sources)
mlmodel.user_defined_metadata["segment_samples"] = str(L)
mlmodel.user_defined_metadata["precision"] = args.precision
mlmodel.user_defined_metadata["license"] = "MIT (facebookresearch/demucs)"
path = out_dir / f"{args.model}.mlpackage"
mlmodel.save(str(path))

pred = mlmodel.predict({"mix": mix.numpy(), "spec": spec.numpy()})
for k, ref in (("freq", ref_freq), ("time", ref_time)):
    got = pred[k]
    err = np.abs(got - ref.numpy()).max()
    snr = 10 * np.log10((ref.numpy() ** 2).sum() / (((got - ref.numpy()) ** 2).sum() + 1e-20))
    print(f"{k}: shape={got.shape} maxabs={err:.4g} SNR={snr:.1f} dB")
print("saved", path)

# Raw little-endian float32 copies for the Swift parity test (Tests/StemSeparationTests).
ref_dir = out_dir / "reference"
ref_dir.mkdir(exist_ok=True)
for name, arr in (("mix", mix[0]), ("spec", spec[0]), ("full", full[0])):
    arr.numpy().astype("<f4").tofile(ref_dir / f"{args.model}-{name}.f32")
