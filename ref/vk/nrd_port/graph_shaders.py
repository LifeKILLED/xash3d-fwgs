"""Materialize the REBLUR kernels as ordinary engine graph shaders.

This transformation changes bindings, sampling access and constant transport;
the translated NVIDIA filter arithmetic remains intact.
"""
import json
from pathlib import Path
import re

PORT = Path(__file__).resolve().parent
OUT = PORT / "generated_reference"
SEQUENCE = [0, 5, 8, 15, 16, 18, 19]
FORMATS = {0: "r8", 2: "r8ui", 15: "r16ui", 17: "r16f", 27: "rgba16f", 28: "r32ui", 30: "r32f", 40: "rgb10_a2"}
# Reference formats above describe the original signal, not allocated images.
STORAGE_FORMATS = {'r8':'rgba8', 'r8ui':'rgba16f', 'r16ui':'rgba32f',
                   'r16f':'rgba16f', 'r32ui':'rgba32f', 'r32f':'rgba32f',
                   'rgb10_a2':'rgba16f', 'rgba8':'rgba8',
                   'rgba16f':'rgba16f', 'rgba32f':'rgba32f'}
PERMANENT = ["depth", "normal", "internal", "history", "fast", "stabilized", "stabilized", "tracking", "tracking"]


def arguments(source, opening):
    depth, start, values = 1, opening + 1, []
    for i in range(start, len(source)):
        if source[i] == "(":
            depth += 1
        elif source[i] == ")":
            depth -= 1
            if not depth:
                return values + [source[start:i].strip()], i + 1
        elif source[i] == "," and depth == 1:
            values.append(source[start:i].strip())
            start = i + 1
    raise ValueError("Unterminated call")


def calls(source, function, replace):
    pattern = re.compile(r"\b" + function + r"\(")
    cursor = 0
    while match := pattern.search(source, cursor):
        args, end = arguments(source, match.end() - 1)
        replacement = replace(args)
        source = source[:match.start()] + replacement + source[end:]
        cursor = match.start() + len(replacement)
    return source


def field_name(name):
    value = re.sub('([A-Z]+)([A-Z][a-z])', r'\1_\2', name[1:])
    return 'reblur_' + re.sub('([a-z0-9])([A-Z])', r'\1_\2', value).lower()


def constant_members(kernels):
    reflection = next(k['reflection'] for k in kernels if k['name'] == 'reblur_prepass_1')
    return reflection['types'][reflection['ubos'][0]['type']]['members']


def uniform_expression(member):
    value = 'ubo.ubo.' + field_name(member['name']) + '[REBLUR_SIGNAL]'
    return value + ('.xy' if member['type'] in ('vec2','ivec2','uvec2') else '')


def common(kernels):
    lines = ['// NVIDIA NRD-derived helpers. See ../../nrd_port/LICENSE.NVIDIA.txt.',
             '#define GLSL', '#include "../ray_interop.h"',
             '#define REBLUR_SIGNAL (1 - NRD_BOUNCE)',
             'layout(set=0,binding=0) uniform UBO { UniformBuffer ubo; } ubo;',
             'bool reblurEnabled() {', '#if NRD_BOUNCE', 'return ubo.ubo.nrd_bounce != 0u;', '#else',
             'return ubo.ubo.nrd_reflection != 0u;', '#endif', '}',
             'ivec2 reblurExtent() { return ivec2(ubo.ubo.reblur_resource_size[REBLUR_SIGNAL].xy); }']
    (OUT / 'reblur_common.glsl').write_text('\n'.join(lines) + '\n')


def sampling_helpers(name, unsigned, extent="reblurExtent()"):
    # Logical extents are independent of the graph allocation capacity.
    typ = 'uvec4' if unsigned else 'vec4'
    lines = [f'{typ} reblurFetch_{name}(ivec2 p) {{',
             f' if(any(lessThan(p,ivec2(0))) || any(greaterThanEqual(p,reblurExtent()))) return {typ}(0);',
             f' return imageLoad({name},p);', '}',
             f'{typ} reblurNearest_{name}(vec2 uv) {{ return imageLoad({name},clamp(ivec2(floor(uv*vec2(reblurExtent()))),ivec2(0),reblurExtent()-1)); }}']
    if not unsigned:
        lines += [f'vec4 reblurLinear_{name}(vec2 uv) {{', ' vec2 p=uv*vec2(reblurExtent())-0.5; ivec2 b=ivec2(floor(p)); vec2 f=fract(p);',
                  f' return mix(mix(imageLoad({name},clamp(b,ivec2(0),reblurExtent()-1)),imageLoad({name},clamp(b+ivec2(1,0),ivec2(0),reblurExtent()-1)),f.x),',
                  f' mix(imageLoad({name},clamp(b+ivec2(0,1),ivec2(0),reblurExtent()-1)),imageLoad({name},clamp(b+ivec2(1,1),ivec2(0),reblurExtent()-1)),f.x),f.y);', '}']
    lines += [f'{typ} reblurGather_{name}(vec2 uv, ivec2 offset) {{', ' ivec2 b=ivec2(floor(uv*vec2(reblurExtent())-0.5))+offset;',
              f' return {typ}(imageLoad({name},clamp(b+ivec2(0,1),ivec2(0),reblurExtent()-1)).x,imageLoad({name},clamp(b+ivec2(1,1),ivec2(0),reblurExtent()-1)).x,',
              f' imageLoad({name},clamp(b+ivec2(1,0),ivec2(0),reblurExtent()-1)).x,imageLoad({name},clamp(b,ivec2(0),reblurExtent()-1)).x);', '}']
    result = '\n'.join(lines).replace('reblurExtent()', extent)
    if unsigned:
        result = result.replace(f'imageLoad({name},', f'reblurUintLoad_{name}(')
    return result


def storage_helpers(name, fmt, unsigned, write):
    lines = []
    if unsigned:
        if fmt == 'r32ui':
            # Each 16-bit half is an exact, finite numeric float32 value.
            decode = 'uint(v.x) | (uint(v.y) << 16u)'
            encode = 'vec4(float(v.x & 65535u),float(v.x >> 16u),0.0,1.0)'
        else:
            mask = 255 if fmt == 'r8ui' else 65535
            decode = 'uint(v.x)'
            encode = f'vec4(float(v.x & {mask}u),0.0,0.0,1.0)'
        if not write:
            lines += [f'uvec4 reblurUintLoad_{name}(ivec2 p) {{',
                      f' vec4 v=imageLoad({name},p); return uvec4({decode},0u,0u,1u);', '}']
        if write:
            lines += [f'void reblurStore_{name}(ivec2 p,uvec4 v) {{ imageStore({name},p,{encode}); }}']
    elif write:
        # Expanded scalar images retain the original missing-channel defaults.
        value = 'vec4(v.x,0.0,0.0,1.0)' if fmt in ('r8','r16f','r32f') else 'v'
        lines += [f'void reblurStore_{name}(ivec2 p,vec4 v) {{ imageStore({name},p,{value}); }}']
    return '\n'.join(lines)


def transform(kernel, resource_map, bounce, frontend=False):
    source = (PORT / 'glsl' / (kernel['name'] + '.comp')).read_text()
    source = re.sub(r'layout\(set = 1, binding = 0, std140\) uniform \w+\s*\{.*?\}\s*(\w+);', '', source, flags=re.S)
    # Frontend's exported UBO uses a different block name/layout.
    source = re.sub(r'layout\(set = 1, binding = 0, std140\) uniform \w+\s*\{.*?\}\s*Frame;', '', source, flags=re.S)
    source = re.sub(r'layout\(set = 1, binding = \d+\) uniform sampler \w+;', '', source)
    declarations = []
    helpers = []
    unsigned_names = set()
    output_names = set()
    reflection = kernel['reflection']
    for category, declared_write in [('separate_images', False), ('images', True)]:
        for binding in reflection.get(category, []):
            old = binding['name']
            real, fmt = resource_map[(declared_write, binding['binding'])]
            write = declared_write
            if declared_write:
                write = bool(re.search(r'\bimageStore\(\s*'+re.escape(old)+r'\s*,', source))
                read = bool(re.search(r'\bimageLoad\(\s*'+re.escape(old)+r'\s*,', source))
                assert not (read and write), (kernel['name'], old, 'read/write image requires explicit graph support')
                if not write:
                    assert read, (kernel['name'], old, 'unused storage image')
                    real = real.removeprefix('out_')
            unsigned = binding['type'].startswith(('uimage', 'utexture'))
            pattern = r'layout\(set = 0, binding = '+str(binding['binding'])+r'(?:, [^)]*)?\) uniform [^;]+;'
            source, count = re.subn(pattern, '', source)
            assert count == 1, (kernel['name'], binding)
            declarations.append(f'layout(set=0,binding={len(declarations)+1},{STORAGE_FORMATS[fmt]}) uniform {"writeonly " if write else "readonly "}image2D {real};')
            helpers.append(storage_helpers(real,fmt,unsigned,write))
            if unsigned:
                unsigned_names.add(real)
            if write:
                output_names.add(real)
            # Keep helper identifiers unique even if graph resources are reused.
            if not write:
                helpers.append(sampling_helpers(real, unsigned, "ubo.ubo.res" if frontend and binding["binding"] < 4 else "reblurExtent()"))
            source = re.sub(r'\b'+old+r'\b', real, source)
    # A resource can be bound more than once by reference variants; active kernels do not do so.
    assert len({v[0] for v in resource_map.values()}) == len(resource_map), (kernel['name'], resource_map)
    source = re.sub(r'REBLUR_\w+Constants\.', 'nrd.', source)
    if frontend:
        source = source.replace('Frame.view', 'transpose(ubo.ubo.view)').replace('Frame.dimensions.xy', 'uvec2(nrd.gRectSize)').replace('Frame.dimensions.z != 0u', 'NRD_BOUNCE != 0')
    source = calls(source, 'texelFetchOffset', lambda a: f'reblurFetch_{a[0]}(({a[1]})+({a[3]}))')
    source = calls(source, 'texelFetch', lambda a: f'reblurFetch_{a[0]}({a[1]})')
    def sampled(a, gather=False):
        match = re.fullmatch(r'u?sampler2D\((\w+),\s*(gLinearClamp|gNearestClamp)\)', a[0])
        assert match, a
        name, sampler = match.groups()
        kind = 'Gather' if gather else ('Linear' if sampler == 'gLinearClamp' else 'Nearest')
        return f'reblur{kind}_{name}({a[1]}' + (',' + (a[2] if len(a)>2 else 'ivec2(0)') if gather else '') + ')'
    source = calls(source, 'textureLod', sampled)
    source = calls(source, 'textureGatherOffset', lambda a: sampled(a, True))
    source = calls(source, 'textureGather', lambda a: sampled(a, True))
    source = calls(source, 'imageLoad', lambda a: f'reblurUintLoad_{a[0]}({a[1]})' if a[0] in unsigned_names else f'imageLoad({",".join(a)})')
    source = calls(source, 'imageStore', lambda a: f'reblurStore_{a[0]}({a[1]},{a[2]})' if a[0] in output_names else f'imageStore({",".join(a)})')
    source = source.replace('#extension GL_EXT_samplerless_texture_functions : require\n', '').replace('#extension GL_EXT_shader_image_load_formatted : require\n','')
    source = source.replace('See ../LICENSE.NVIDIA.txt and ../LICENSE.MathLib.txt.', 'See ../../nrd_port/LICENSE.NVIDIA.txt and ../../nrd_port/LICENSE.MathLib.txt.').replace('See ../LICENSE.NVIDIA.txt.', 'See ../../nrd_port/LICENSE.NVIDIA.txt.')
    insertion = f'\n#define NRD_BOUNCE {int(bounce)}\n#include "reblur_common.glsl"\n' + '\n'.join(declarations + helpers) + '\n'
    # Extensions must precede declarations in GLSL.
    end = source.index('layout(local_size_')
    source = source[:end] + insertion + source[end:]
    # The engine always dispatches ceil(screen/8) groups along both axes.
    # Cull entire surplus groups before any shared-memory access or barrier.
    if frontend:
        group_limit = 'ubo.ubo.reblur_groups_8x8_8x16[REBLUR_SIGNAL].xy'  # 8x8 pixel span
    elif 'ClassifyTiles' in kernel['source'] or 'PrePass' in kernel['source']:
        group_limit = 'ubo.ubo.reblur_groups_16x16[REBLUR_SIGNAL].xy'  # 16x16 pixel span
    else:
        assert reflection['entryPoints'][0]['workgroup_size'][:2] == [8,16]
        group_limit = 'ubo.ubo.reblur_groups_8x8_8x16[REBLUR_SIGNAL].zw'  # 8x16 pixel span
    source = re.sub(r'(void main\(\)\s*\{)',
                    r'\1\n    if(!reblurEnabled()) return;\n    if(any(greaterThanEqual(gl_WorkGroupID.xy,' + group_limit + r'))) return;', source)
    # Read the existing frame UBO directly; no decoded constant object.
    members = {m['name']: m for m in constant_members(json.loads((PORT / 'kernels.json').read_text())['kernels'])}
    source = re.sub(r'\bnrd\.(g\w+)', lambda match: uniform_expression(members[match[1]]), source)
    assert not re.search(r'\b(texture2D|utexture2D|sampler2D|textureLod|texelFetch|textureGather)\b', source), (kernel['name'], re.findall(r'.*(?:texture2D|sampler2D|textureGather|textureLod|texelFetch).*', source))
    from readable_shaders import restore
    stage = 'prepare' if frontend else kernel['source'].removeprefix('REBLUR_').removesuffix('.cs.hlsl').lower()
    source = restore(source,stage)
    frame_transforms = {
        'world_to_clip': 'reblurWorldToClip(false)',
        'world_to_clip_prev': 'reblurWorldToClip(true)',
        'view_to_clip': 'transpose(reblurProjection(false))',
        'view_to_world': 'transpose(reblurViewToWorld())',
        'world_to_view_prev': 'transpose(reblurWorldToView(true))',
        'world_prev_to_world': 'mat4(1.0)',
        'camera_delta': 'vec4(reblurCameraDelta(), 0.0)',
        'view_vector_world': 'vec4(reblurViewDirection(false), 0.0)',
        'view_vector_world_prev': 'vec4(reblurViewDirection(true), 0.0)',
    }
    for field, expression in frame_transforms.items():
        source = source.replace(f'ubo.ubo.reblur_{field}[REBLUR_SIGNAL]', expression)
    return source


def generate():
    OUT.mkdir(exist_ok=True)
    kernels = json.loads((PORT / 'kernels.json').read_text())['kernels']
    frontend = json.loads((PORT / 'frontend.json').read_text())
    graphs = json.loads((PORT / 'graphs.json').read_text())
    common(kernels)
    entries = {}
    for signal, graph in zip(('bounce', 'reflection'), graphs.values()):
        bounce = signal == 'bounce'
        prefix = 'reblur_' + signal
        external = {0: ('motion','rgba16f'),1: ('normal','rgb10_a2'),2: ('viewz','r32f'),6: ('signal','rgba16f'),7: ('signal','rgba16f'),18: ('work','rgba16f'),19: ('work','rgba16f')}
        def resource(ref, write=False, seen=None):
            rid = ref['id']
            if rid < 1000:
                name, fmt = external[rid]
                return ('out_' if write else '') + prefix + '_' + name, fmt
            if rid >= 2000:
                index = rid - 2000
                return ('out_' if write else '') + prefix + '_scratch_' + str(index), FORMATS[graph['transient'][index]['format']]
            index = rid - 1000
            key = PERMANENT[index]
            temporal = 'temporal_' + prefix + '_' + key
            return ('out_' if write else ('' if key in seen else 'prev_')) + temporal, FORMATS[graph['permanent'][index]['format']]
        raw = [('position_t','rgba32f'),('normals_gs','rgba16f'),('material_rmxx','rgba8'),('geometry_prev_position','rgba32f'),('indirect_diffuse' if bounce else 'indirect_specular','rgba16f'),('first_bounce_direction' if bounce else 'reflection_direction_pdf','rgba32f')]
        mapping = {(False,i): value for i,value in enumerate(raw)}
        mapping.update({(True,64+i): ('out_'+prefix+'_'+name,fmt) for i,(name,fmt) in enumerate([external[1],external[2],external[0],external[6]])})
        shader_name = signal + '_prepare'
        (OUT / (shader_name+'.comp')).write_text(transform(frontend,mapping,bounce,True))
        entries[prefix+'_prepare'] = {'comp':'reblur/'+shader_name}
        seen = set()
        for index in SEQUENCE:
            stage = graph['passes'][index]
            kernel = kernels[stage['kernel']]
            mapping = {}
            for category, write, refs in [('separate_images',False,stage['inputs']),('images',True,stage['outputs'])]:
                for binding in kernel['reflection'].get(category,[]):
                    mapping[write,binding['binding']] = resource(refs[binding['binding']-(64 if write else 0)],write,seen)
            stage_name = kernel['source'].removeprefix('REBLUR_').removesuffix('.cs.hlsl').lower()
            shader_name = signal + '_' + stage_name
            (OUT / (shader_name+'.comp')).write_text(transform(kernel,mapping,bounce))
            desc = {'comp':'reblur/'+shader_name}
            entries[prefix+'_'+stage_name] = desc
            seen.update(PERMANENT[r['id']-1000] for r in stage['outputs'] if 1000<=r['id']<2000)
    return entries


if __name__ == '__main__':
    print(json.dumps(generate(),indent=2))
