#!/usr/bin/env python3
"""Run Musicless's unmodified reference DSP; one fresh process per measurement.

pip install numpy onnxruntime soundfile
python tools/musicless/benchmark.py MODEL CLIP.wav --threads 1 --output vocals.npy
"""
import argparse
import json
import resource
import time

import numpy as np
import onnxruntime as ort
import soundfile as sf

import reference

parser = argparse.ArgumentParser()
parser.add_argument('model')
parser.add_argument('clip')
parser.add_argument('--threads', type=int, default=1)
parser.add_argument('--output', required=True)
parser.add_argument('--compare')
args = parser.parse_args()
x, rate = sf.read(args.clip, dtype='float32', always_2d=True)
assert rate == reference.RATE and x.shape[1] == 2 and np.isfinite(x).all()
options = ort.SessionOptions()
options.intra_op_num_threads = args.threads
options.inter_op_num_threads = 1
options.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
options.add_free_dimension_override_by_name('num_splits', 1)
start = time.perf_counter()
reference._session = ort.InferenceSession(args.model, options, providers=['CPUExecutionProvider'])
load = time.perf_counter() - start
start = time.perf_counter()
y = reference.vocals(x)
elapsed = time.perf_counter() - start
assert y.shape == x.shape and np.isfinite(y).all()
np.save(args.output, y)
result = dict(model=args.model, ort=ort.__version__, threads=args.threads,
              duration_s=len(x) / rate, load_s=load, pipeline_s=elapsed,
              rtf=elapsed / (len(x) / rate), peak_rss_mib=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024)
if args.compare:
    baseline = np.load(args.compare)
    assert baseline.shape == y.shape
    result['sdr_vs_fp32_db'] = float(10 * np.log10(np.sum(baseline ** 2) / np.sum((baseline - y) ** 2)))
print(json.dumps(result, indent=2))
