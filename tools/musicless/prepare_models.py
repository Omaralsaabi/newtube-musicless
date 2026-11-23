#!/usr/bin/env python3
"""Build download assets: symbolic-frame U-Nets, fp16 storage/fp32 arithmetic.

Usage: prepare_models.py ORIGINAL_SHERPA_DIR [OUTPUT_DIR]
The output defaults to tools/musicless/dist (never upload automatically).
SHA256SUMS hashes decompressed models, not their gzip transport containers.
"""
import gzip
import hashlib
from pathlib import Path
import sys

import numpy as np
import onnx
from onnx import helper, numpy_helper

source = Path(sys.argv[1])
target = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(__file__).parent / 'dist'
target.mkdir(parents=True, exist_ok=True)
manifest = []
for stem in ('vocals', 'accompaniment'):
    model = onnx.load(source / f'{stem}.onnx')
    for value in [*model.graph.input, *model.graph.output]:
        value.type.tensor_type.shape.dim[2].dim_param = 'frames'
    casts = []
    for weight in model.graph.initializer:
        if weight.data_type == onnx.TensorProto.FLOAT:
            name = weight.name
            weight.CopyFrom(numpy_helper.from_array(numpy_helper.to_array(weight).astype(np.float16), name + '_fp16'))
            casts.append(helper.make_node('Cast', [name + '_fp16'], [name], to=onnx.TensorProto.FLOAT))
    nodes = list(model.graph.node)
    del model.graph.node[:]
    model.graph.node.extend(casts + nodes)
    onnx.checker.check_model(model)
    data = model.SerializeToString()
    name = f'{stem}.onnx'
    (target / name).write_bytes(data)
    compressed = gzip.compress(data, compresslevel=9, mtime=0)
    (target / (name + '.gz')).write_bytes(compressed)
    digest = hashlib.sha256(data).hexdigest()
    manifest.append(f'{digest}  {name}\n')
    print(f'{name}: {len(data)} bytes; gzip {len(compressed)} bytes; sha256 {digest}')
(target / 'SHA256SUMS').write_text(''.join(manifest))
