"""Validate the graph migration without compiling shaders or starting Vulkan.

Exercise the real graph serializer using declaration-only shader stand-ins.
This checks bindings, formats, history dependencies and UBO group limits;
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
assert binary.read(4) == b'MEAT'
def u32():
    return struct.unpack('<I', binary.read(4))[0]
def string():
    return binary.read(u32()).split(b'\0')[0].decode()

resources = []
for _ in range(u32()):
    name, kind, count = string(), u32(), u32()
    record = dict(name=name, kind=kind)
    if kind == 3:
        record.update(format=u32(), previous=u32())
    resources.append(record)
by_name = {r['name']: r for r in resources}
history = [r for r in resources if r['name'].startswith('prev_temporal_')]
assert len(history) == 13, len(history)
for resource in history:
    current = resources[resource['previous']-1]
    assert current['name'] == resource['name'].removeprefix('prev_')
    assert resource['format'] == current['format']

# Consume the original MEAT shader and compute-pass records to EOF. There
# must be no added resource sizes or dispatch fields in the binary format.
shader_count=u32()
for _ in range(shader_count):
    string()
    binary.read(u32())
assert u32() == 17
for expected_name in selected:
    assert u32() == 1  # compute
    assert string() == expected_name
    for _ in range(u32()):
        header,resource_index,stages=u32(),u32(),u32()
        assert resource_index < len(resources)
    assert u32() < shader_count
assert binary.read() == b''
for record in resources:
    assert record['kind'] == 3 or record['name'] == 'ubo'
for desc in selected.values():
    assert set(desc) == {'comp'}
assert 'extent_divisor' not in (VK / 'vulkan/VMeatpipe.c').read_text()

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

# The unchanged dispatcher launches ceil(screen/8) groups. CPU UBO limits
# retain exactly the original active groups for each kernel and signal.
for width,height in [(63,31),(1152,864),(1921,1081),(3840,2160)]:
    launched=((width+7)//8,(height+7)//8)
    for path in (VK / 'shaders/reblur').glob('*.comp'):
        text=path.read_text()
        logical=(width//2,height//2) if path.name.startswith('bounce_') else (width,height)
        if path.stem.endswith('prepare'):
            field,channels,span='reblur_groups_8x8_8x16','xy',(8,8)
        elif path.stem.endswith(('prepass','classifytiles')):
            field,channels,span='reblur_groups_16x16','xy',(16,16)
        else:
            field,channels,span='reblur_groups_8x8_8x16','zw',(8,16)
        limit=tuple((value+step-1)//step for value,step in zip(logical,span))
        assert all(n<=available for n,available in zip(limit,launched)),path
        assert all(n*step>=value for n,step,value in zip(limit,span,logical)),path
        guard=f'if(any(greaterThanEqual(gl_WorkGroupID.xy,ubo.ubo.{field}[REBLUR_SIGNAL].{channels}))) return;'
        main=text[text.index('void main()'):]
        assert main.split('{',1)[1].strip().startswith('if(!reblurEnabled()) return;\n    '+guard),path
        if 'barrier();' in main:
            assert main.index(guard)<main.index('barrier();'),path
        assert 'gl_NumWorkGroups' not in text,path

for path in (VK / 'shaders/reblur').glob('*.comp'):
    text = path.read_text()
    assert not re.search(r'\b(?:texture2D|utexture2D|sampler2D|textureLod|textureGather\w*|texelFetch\w*)\b',text), path
    assert 'if(!reblurEnabled()) return;' in text
    assert 'uimage2D' not in text
    for fmt in re.findall(r'layout\(set=0,binding=\d+,(\w+)\)', text):
        assert fmt in formats, (path, fmt)

# Every filter parameter is a named field of the existing shared UBO, read
# directly by GLSL and filled directly by the CPU helper (no packed packet).
ubo_header=(VK / 'shaders/ray_interop.h').read_text()
ubo_fields={name:(typ,int(count) if count else None) for typ,name,count in re.findall(
    r'\b(mat4|vec4|vec2|ivec4|uvec4|uvec2)\s+(reblur_\w+)(?:\[(\d+)\])?;',ubo_header)}
cpp=(VK / 'nrd_port/cpu.cpp').read_text()
assert len(ubo_fields)==83,len(ubo_fields)
for name in ubo_fields:
    assert 'ubo->'+name+'[signal]' in cpp,name
for path in (VK / 'shaders/reblur').glob('*'):
    text=path.read_text()
    for field in re.findall(r'ubo\.ubo\.(reblur_\w+)\[REBLUR_SIGNAL\]',text):
        assert field in ubo_fields,(path,field)
    assert not re.search(r'\b(?:ReblurConstants|NrdConstants|reblurData|reblurLoadConstants)\b',text),path
assert 'nrd_bounce_constants' not in ubo_header and 'nrd_reflection_constants' not in ubo_header
assert not re.search(r'\b(?:ReblurConstants|NrdConstants|SharedConstants|NrdFrame)\b',cpp)
# Shared C/std140 layout: matrix/vector arrays have 16-byte-aligned strides;
# per-signal scalar pairs occupy vec2/uvec2, with explicit padding before groups.
offset=0
for typ,name,count in [(t,n,int(c) if c else None) for t,n,c in re.findall(
        r'\b(mat4|vec4|vec2|ivec4|uvec4|uvec2)\s+(reblur_\w+)(?:\[(\d+)\])?;',ubo_header)]:
    if name=='reblur_groups_8x8_8x16':
        assert offset%16==8
        offset+=8 # PAD(2) in C, implicit std140 array alignment in GLSL
    size=64 if typ=='mat4' else (8 if typ in ('vec2','uvec2') else 16)
    alignment=16 if count or size>=16 else 8
    assert offset%alignment==0,(name,offset)
    offset+=size*(count or 1)
assert offset%16==0

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

print('REBLUR graph checks passed: 17 nodes, 13 history pairs, original MEAT format, existing RGBA formats, producer order, named UBO fields and layout, group guards, exact integer storage.')
