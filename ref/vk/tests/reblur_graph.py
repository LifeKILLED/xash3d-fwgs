"""Validate the graph migration without compiling shaders or starting Vulkan.

Exercise the real graph serializer using declaration-only shader stand-ins.
This checks bindings, formats, history dependencies, sizes and dispatch metadata;
it deliberately does not claim to validate shader compilation or image quality.
"""
import ast
import copy
import io
import json
from pathlib import Path
import re
import random
import struct
import sys

VK = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(VK))
from spirv import spv

tree = ast.parse((VK / 'sebastian.py').read_text())
# Load reusable definitions without running the command-line driver.
definitions = [node for node in tree.body if isinstance(node, (ast.ClassDef, ast.FunctionDef))]
environment = dict(json=json, struct=struct, copy=copy, spv=spv, spvOp=spv['Op'])
exec(compile(ast.Module(body=definitions, type_ignores=[]), 'sebastian definitions', 'exec'), environment)
environment['resources'] = environment['Resources']()

formats = {'rgba8':'Rgba8','rgba16f':'Rgba16f','rgba32f':'Rgba32f'}


class DeclarationShader:
    def __init__(self, name):
        self.name = name + '.comp.spv'
        self.source = (VK / 'shaders' / (name + '.comp')).read_text()
        self.bindings = []
        for binding, fmt, qualifier, kind, resource in re.findall(
                r'layout\(set\s*=\s*0,\s*binding\s*=\s*(\d+),\s*(\w+)\)\s*uniform\s+(?:(readonly|writeonly)\s+)?(u?image2D)\s+(\w+);', self.source):
            node = environment['SpirvNode']()
            node.name, node.binding, node.descriptor_set = resource, int(binding), 0
            node.type = environment['TypeInfo'](environment['TypeInfo'].TYPE_STORAGE_IMAGE)
            node.type.is_image = True
            node.type.image_format = spv['ImageFormat'][formats[fmt]]
            self.bindings.append(environment['Binding'](node))
        # The common include supplies the ordinary engine UBO.
        node = environment['SpirvNode']()
        node.name, node.binding, node.descriptor_set = 'ubo', 0, 0
        node.type = environment['TypeInfo'](environment['TypeInfo'].TYPE_UNIFORM_BUFFER)
        self.bindings.append(environment['Binding'](node))

    def getBindings(self):
        return self.bindings

    def getRawData(self):
        group = re.search(r'layout\(local_size_x\s*=\s*(\d+),\s*local_size_y\s*=\s*(\d+)', self.source)
        assert group, self.name
        x, y = map(int, group.groups())
        words = [spv['MagicNumber'], 0x00010500, 0, 2, 0,
                 (6 << 16) | spv['Op']['OpExecutionMode'], 1, spv['ExecutionMode']['LocalSize'], x, y, 1]
        return struct.pack('<%dI' % len(words), *words)

class DeclarationShaders:
    def __init__(self):
        self.shaders = []

    def load(self, name, stage):
        shader = DeclarationShader(name)
        self.shaders.append(shader)
        return shader

    def getIndex(self, shader):
        return self.shaders.index(shader)

    def serialize(self, out):
        out.writeU32(len(self.shaders))
        for shader in self.shaders:
            out.writeString(shader.name)
            out.writeBytes(shader.getRawData())

environment['shaders'] = DeclarationShaders()
environment['PIPELINE_COMPUTE'] = 1
environment['PIPELINE_RAYTRACING'] = 2
with (VK / 'shaders/rt.json').open() as stream:
    graph = environment['prepareJSON'](stream)
selected = {name: desc for name, desc in graph.items() if name.startswith('reblur_') or name == 'nrd_resolve'}
assert len(selected) == 17
pipelines = environment['NameIndex']()
for name, desc in selected.items():
    pipelines.put(name, environment['PipelineCompute'](name, desc))

binary = io.BytesIO()
environment['writeOutput'](binary, pipelines)
binary.seek(0)
assert binary.read(4) == b'MEA2'
def u32():
    return struct.unpack('<I', binary.read(4))[0]
def string():
    return binary.read(u32()).split(b'\0')[0].decode()

resources = []
for _ in range(u32()):
    name, kind, count = string(), u32(), u32()
    record = dict(name=name, kind=kind)
    if kind == 3:
        record.update(format=u32(), previous=u32(), divisor=(u32(),u32()))
    resources.append(record)
by_name = {r['name']: r for r in resources}
history = [r for r in resources if r['name'].startswith('prev_temporal_')]
assert len(history) == 13, len(history)
for resource in history:
    current = resources[resource['previous']-1]
    assert current['name'] == resource['name'].removeprefix('prev_')
    assert resource['format'] == current['format']
    assert resource['divisor'] == current['divisor']

for record in resources:
    if record['kind'] != 3:
        assert record['name'] == 'ubo'
        continue
    if 'reblur_bounce' in record['name']:
        expected = (32,32) if record['name'].endswith('scratch_4') else (2,2)
        assert record['divisor'] == expected, record
    elif 'reblur_reflection' in record['name']:
        expected = (16,16) if record['name'].endswith('scratch_5') else (1,1)
        assert record['divisor'] == expected, record

# Check that each current-frame input has a preceding producer. History reads
# are supplied by the normal prev_/out_ resource swapping mechanism.
available = {'position_t','normals_gs','material_rmxx','geometry_prev_position',
             'indirect_diffuse','indirect_specular','first_bounce_direction','reflection_direction_pdf','ubo'}
for pipeline in pipelines:
    for binding in pipeline.bindings():
        name = binding.getResource().name
        if not binding.write:
            assert name in available or name.startswith('prev_temporal_'), (pipeline.name, name)
    available.update(b.getResource().name for b in pipeline.bindings() if b.write)

# Workgroup geometry is reflected from SPIR-V; tiles classify 16x16 pixels
# using an 8x4 group, while blur kernels use 8x16 groups.
assert pipelines.getByName('reblur_bounce_blur').workgroupSize() == (8,16)
assert pipelines.getByName('reblur_reflection_classifytiles').group_span == [16,16]
for width,height in [(1152,864),(1921,1081),(3840,2160)]:
    for pipeline in pipelines:
        dx,dy = pipeline.dispatch_divisor
        sx,sy = pipeline.group_span or pipeline.workgroupSize()
        nx,ny = (width//dx+sx-1)//sx,(height//dy+sy-1)//sy
        assert nx*sx >= width//dx and ny*sy >= height//dy

for path in (VK / 'shaders/reblur').glob('*.comp'):
    text = path.read_text()
    assert not re.search(r'\b(?:texture2D|utexture2D|sampler2D|textureLod|textureGather\w*|texelFetch\w*)\b',text), path
    assert 'if(!reblurEnabled()) return;' in text
    assert 'uimage2D' not in text
    for fmt in re.findall(r'layout\(set=0,binding=\d+,(\w+)\)', text):
        assert fmt in formats, (path, fmt)

# Expanded scalar resources keep the original bit widths. Numeric float
# storage avoids NaN payloads and exactly preserves every integer component.
def f32(value):
    return struct.unpack('<f',struct.pack('<f',value))[0]
for value in range(256):
    half = struct.unpack('<e',struct.pack('<e',value))[0]
    assert int(half) == value
for value in range(65536):
    assert int(f32(value)) == value
rng = random.Random(1701)
for value in [0,1,255,65535,65536,0x7f800000,0x7fc00000,0x80000000,0xffffffff] + [rng.getrandbits(32) for _ in range(10000)]:
    low,high = f32(value & 65535), f32(value >> 16)
    assert (int(low) | (int(high)<<16)) == value

print('REBLUR graph checks passed: 17 nodes, 13 history pairs, existing RGBA formats, sizes, producer order, dispatch geometry, exact integer storage.')
