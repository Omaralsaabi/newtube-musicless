#!/usr/bin/env python3
"""Copy sherpa-onnx's two original fp32 U-Nets, allowing 128/256/512 time frames.

Usage: prepare_models.py <extracted sherpa directory> <assets/musicless directory>
Only input/output shape metadata changes; weights/nodes are unmodified.
"""
import hashlib
from pathlib import Path
import sys

import onnx

source, target = map(Path, sys.argv[1:])
target.mkdir(parents=True, exist_ok=True)
for stem in ('vocals', 'accompaniment'):
    model = onnx.load(source / f'{stem}.onnx')
    for value in [*model.graph.input, *model.graph.output]:
        value.type.tensor_type.shape.dim[2].dim_param = 'frames'
    onnx.checker.check_model(model)
    path = target / f'{stem}.onnx'
    onnx.save(model, path)
    print(stem, path.stat().st_size, hashlib.sha256(path.read_bytes()).hexdigest())
