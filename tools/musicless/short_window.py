#!/usr/bin/env python3
"""Try symbolic time on a COPY of the merged graph; compare first-window waveforms."""
import argparse
import json
import time
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort
import soundfile as sf

import reference

parser = argparse.ArgumentParser()
parser.add_argument('model')
parser.add_argument('clip')
parser.add_argument('copy', help='Output symbolic model (never overwrite the original)')
parser.add_argument('--separate-models', help='Directory of symbolic vocals/accompaniment graphs')
args = parser.parse_args()
assert Path(args.model).resolve() != Path(args.copy).resolve()
model = onnx.load(args.model)
for value in [*model.graph.input, *model.graph.output]:
    value.type.tensor_type.shape.dim[2].dim_param = 'frames'
onnx.save(model, args.copy)
options = ort.SessionOptions()
options.intra_op_num_threads = 2 if args.separate_models else 1
options.inter_op_num_threads = 1
if args.separate_models:
    options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_BASIC
options.enable_cpu_mem_arena = options.enable_mem_pattern = False
options.add_session_config_entry('session.intra_op.allow_spinning', '0')
if args.separate_models:
    class SeparateSessions:
        def __init__(self):
            self.sessions = [ort.InferenceSession(str(Path(args.separate_models) / f'{stem}.onnx'),
                             options, providers=['CPUExecutionProvider']) for stem in ('vocals', 'accompaniment')]

        def run(self, _, inputs):
            v, a = [s.run(None, {s.get_inputs()[0].name: inputs['x']})[0] for s in self.sessions]
            return [(v + 5e-11) / (v + 2 * a + 1e-10)]

    session = SeparateSessions()
else:
    session = ort.InferenceSession(args.copy, options, providers=['CPUExecutionProvider'])
x, rate = sf.read(args.clip, dtype='float32', always_2d=True)
assert rate == reference.RATE and x.shape[1] == 2
baseline = None
for frames in (512, 256, 128, 64):
    reference.FRAMES = frames
    reference.WINDOW = frames * reference.HOP
    reference._INDEX = np.arange(frames + 1)[:, None] * reference.HOP + np.arange(reference.N_FFT)[None, :]
    reference._weight = None
    block = x[:reference.WINDOW].T.astype(np.float64)
    elapsed = []
    try:
        for trial in range(3):
            start = time.perf_counter()
            spec = reference.stft(block)
            gain = np.clip(reference.INPUT_RMS / (np.sqrt((block ** 2).mean()) + 1e-9),
                           1 / reference.MAX_INPUT_GAIN, reference.MAX_INPUT_GAIN)
            magnitude = (np.abs(spec[:, None, :frames]) * gain).astype(np.float32)
            mask = session.run(None, {'x': magnitude})[0][:, 0]
            assert mask.shape == (2, frames, reference.BINS) and np.isfinite(mask).all()
            output = reference.istft(spec * np.concatenate([mask, mask[:, -1:]], axis=1))
            elapsed.append((time.perf_counter() - start) * 1000)
        if baseline is None:
            baseline = output.copy()
            sdr = None
        else:
            span = baseline[:, :output.shape[1]]
            sdr = float(10 * np.log10(np.sum(span ** 2) / np.sum((span - output) ** 2)))
        print(json.dumps(dict(frames=frames, pipeline_ms=elapsed,
                              median_ms=float(np.median(elapsed)), sdr_db=sdr)))
    except Exception as error:
        print(json.dumps(dict(frames=frames, error=str(error))))
