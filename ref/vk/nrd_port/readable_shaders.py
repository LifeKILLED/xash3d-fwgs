"""Restore readable loops in the pinned, flattened GLSL (offline only).

Every spatial tap body is checked for alpha-equivalence before folding it.
No shader compilation or build-time dependency is introduced.
"""
import re
import textwrap
import json
from pathlib import Path


def rename(source, names):
    return re.sub(r'\b_\d+\b', lambda m: names.get(m[0], m[0]), source)


def fold_spatial(source):
    tracks_hit_distance = 'reblurStore_out_reblur_reflection_scratch_2' in source
    mirrors = list(re.finditer(r'^([ ]*)vec2 (_\d+) = spvNMin\(vec2\(1\.0\) - abs\(vec2\(1\.0\) - \(fract\((_[0-9]+) \* 0\.5\)', source, re.M))
    assert len(mirrors) == 8
    accumulator = next(line for line in source.splitlines() if line.count(' + (') >= 7 and 'spvNMax' in line)
    pairs = re.findall(r'\((_[0-9]+) \* (_[0-9]+)\)', accumulator)
    assert len(pairs) == 8
    indent = mirrors[0][1]
    sample_uvs = [m[3] for m in mirrors]
    first_uv = re.search(r'^'+indent+r'vec2 '+sample_uvs[0]+r' = .*;\n', source, re.M)
    center = re.search(r'= \(+(_\d+) \+', accumulator)[1]
    result = re.search(r'(_\d+) =', accumulator)[1]
    bodies, prefixes, ends = [], [], []
    start = first_uv.start()
    for mirror, (_,weight) in zip(mirrors,pairs):
        weight_line = re.search(r'^'+indent+r'float '+weight+r' = .*;\n', source[mirror.start():], re.M)
        end = mirror.start()+weight_line.end()
        prefixes.append(source[start:mirror.start()])
        bodies.append(source[mirror.start():end])
        ends.append(end)
        start = end

    # The compiler hoisted center material comparison out of taps 1..7.
    material = re.search(r'^'+indent+r'float (_\d+) = spvNMax\(_\d+\.w \* 3\.0, ubo\.ubo\.reblur_(?:diff|spec)_min_material\[REBLUR_SIGNAL\]\);\n', bodies[0], re.M)
    assert material
    bodies[0] = bodies[0].replace(material[0], '')
    invariants = material[0]
    if tracks_hit_distance:
        roughness_fade = re.search(r'^'+indent+r'float (_\d+) = clamp\(\(_\d+ - 0\.5\) \* 2\.0, 0\.0, 1\.0\);\n', bodies[0], re.M)
        assert roughness_fade
        bodies[0] = bodies[0].replace(roughness_fade[0], '')
        invariants += roughness_fade[0]
    reference = None
    for index,body in enumerate(bodies):
        if tracks_hit_distance and index == 7:
            # The final hash value has no following tap, so DXC inlined it.
            inline_hash = re.search(r'\((_\d+) \^ \(\1 >> 16u\)\) >> 9u',body)
            assert inline_hash
            body = body.replace(inline_hash[0], '_999999 >> 9u')
            insertion = re.search(r'^'+indent+r'float _\d+;\n',body,re.M).start()
            body = body[:insertion]+indent+'uint _999999 = '+inline_hash[1]+' ^ ('+inline_hash[1]+' >> 16u);\n'+body[insertion:]
        # The inherited z component is overwritten on the next statement.
        body = re.sub(r'(vec3 _\d+ = vec3\(_\d+\.x, _\d+\.y, )_\d+\.z(\);)', r'\g<1>0.0\2', body)
        names = {sample_uvs[index]:'sampleUv'}
        if tracks_hit_distance:
            state = re.search(r'uint _\d+ = \((_[0-9]+) \^ \(\1 >> 16u\)\)',body)[1]
            tracking = re.search(r'spvNMin\((_[0-9]+), _\d+\)',body)[1]
            names.update({state:'rngState',tracking:'trackingHitDistance'})
            if index == 0:
                initial_state, initial_tracking = state, tracking
            tracking_result = re.search(r'float (_\d+);\n',body)[1]
            hash_result = re.findall(r'uint (_\d+) =',body)[-1]
        declarations = re.findall(r'\b(?:float|uint|vec[234]|uvec2) (_\d+)\s*[=;]', body)
        names.update({name:'tapValue'+str(i) for i,name in enumerate(declarations)})
        normalized = rename(body,names)
        normalized = re.sub(r'0\.(?:51685130596160888671875|84789371490478515625)', 'sampleGaussianWeight', normalized)
        if reference is None:
            reference = normalized
            local_names = names
        else:
            assert normalized == reference, ('Spatial tap differs',index,normalized,reference)

    # Retain the exact UV expressions, Gaussian values and accumulation order.
    uv_setup = ''.join(prefixes)
    loop = invariants+uv_setup
    loop += indent+'const float sampleGaussianWeights[8] = float[8](\n'+indent+'    '+', '.join(['0.51685130596160888671875']*4+['0.84789371490478515625']*4)+');\n'
    loop += indent+'vec2 sampleUvs[8] = vec2[8]('+', '.join(sample_uvs)+');\n'
    loop += indent+'vec4 radianceSum = '+center+';\n'+indent+'float weightSum = 1.0;\n'
    if tracks_hit_distance:
        loop += indent+'uint rngState = '+initial_state+';\n'+indent+'float trackingHitDistance = '+initial_tracking+';\n'
    loop += indent+'for (int sampleIndex = 0; sampleIndex < 8; ++sampleIndex)\n'+indent+'{\n'
    loop += indent+'    vec2 sampleUv = sampleUvs[sampleIndex];\n'+indent+'    float sampleGaussianWeight = sampleGaussianWeights[sampleIndex];\n'
    loop += '\n'.join('    '+line for line in reference.rstrip().splitlines())+'\n'
    if tracks_hit_distance:
        # Use tap-zero local IDs to name the canonical state outputs.
        first_tracking_result = re.search(r'float (_\d+);\n',bodies[0])[1]
        first_hash_result = re.findall(r'uint (_\d+) =',bodies[0])[-1]
        loop += indent+'    rngState = '+local_names[first_hash_result]+';\n'
        loop += indent+'    trackingHitDistance = '+local_names[first_tracking_result]+';\n'
    loop += indent+'    radianceSum += '+local_names[pairs[0][0]]+' * '+local_names[pairs[0][1]]+';\n'
    loop += indent+'    weightSum += '+local_names[pairs[0][1]]+';\n'+indent+'}\n'
    declaration = 'vec4 ' if re.search(r'\bvec4 '+result+r' =',accumulator) else ''
    acc_end = source.index(accumulator)+len(accumulator)+1
    trailing = source[ends[-1]:source.index(accumulator)]
    if tracks_hit_distance:
        loop += rename(trailing,{tracking_result:'trackingHitDistance'})
    else:
        assert not trailing.strip()
    loop += indent+declaration+result+' = radianceSum * (1.0 / spvNMax(weightSum, 1.0000000036274937255387218471014e-15));\n'
    source = source[:first_uv.start()]+loop+source[acc_end:]
    common = ['mirroredUv','samplePixel','sampleViewDepth','sampleViewXY','sampleViewPosition','sampleNormalRoughness']
    if '#define NRD_BOUNCE 1' in source:
        roles = common+['encodedNormalX','encodedNormalY','octNormalX','octNormalY','sampleNormalUnnormalized','normalDot','normalAngleWeight','planeWeight','geometryWeight','sampleRadiance','hitDistanceDelta','sampleWeight']
    elif not tracks_hit_distance:
        roles = common+['signedRoughness','encodedNormalX','encodedNormalY','octNormalX','octNormalY','sampleRoughness','sampleNormalUnnormalized','normalDot','normalAngleWeight','roughnessWeight','planeWeight','geometryWeight','sampleRadiance','hitDistanceDelta','sampleWeight']
    else:
        roles = common+['signedRoughness','encodedNormalX','encodedNormalY','octNormalX','octNormalY','sampleRoughness','sampleNormalUnnormalized','normalDot','normalAngleWeight','roughnessWeight','planeWeight','geometryWeight','sampleRadiance','sampleHitDistanceNormalized','sampleHitDistance','hashMix0','hashMix1','hashValue','nextTrackingHitDistance','hitDistanceDelta','sampleWeight']
    source = re.sub(r'\btapValue(\d+)\b',lambda m:roles[int(m[1])],source)
    names = {center:'centerRadiance',result:'filteredRadiance',material[1]:'centerMaterial'}
    if tracks_hit_distance:
        names[roughness_fade[1]]='roughnessContactFade'
    for pattern,role in [
        (r'float normalDot = dot\((_[0-9]+),','normalWorld'),
        (r'dot\((_[0-9]+), sampleViewPosition\)','normalView'),
        (r'\* (_\d+)\) - 1\.0\) \* \(-1\.0\), 0\.0, 1\.0\);\n\s*float (?:roughnessWeight|planeWeight)', 'normalWeightScale'),
        (r'\(dot\(_\d+, sampleViewPosition\) \* (_\d+)\)','planeWeightScale'),
        (r'\(dot\(_\d+, sampleViewPosition\) \* _\d+\) \+ (_\d+)','planeWeightBias'),
        (r'\)\.xy \* \((_[0-9]+) \? sampleViewDepth','isPerspective'),
    ]:
        match=re.search(pattern,source)
        if match:
            names[match[1]]=role
    names.update({name:'kernelUv'+str(i) for i,name in enumerate(sample_uvs)})
    source=rename(source,names)
    return source


def classify_tiles(source):
    prefix = 'bounce' if '#define NRD_BOUNCE 1' in source else 'reflection'
    tile_store=re.search(r'void (reblurStore_out_\w+)\(',source)[1]
    start=source.index('    bool ',source.index('void main()'))
    source=source[:start]+'''    bool isFirstThread = gl_LocalInvocationIndex == 0u;
    if (isFirstThread)
        s_Sum = 0;
    barrier();

    ivec2 pixelBase = ivec2(gl_WorkGroupID.xy * 16u + gl_LocalInvocationID.xy * uvec2(2u, 4u));
    int skyPixelCount = 0;
    for (int sampleX = 0; sampleX < 2; ++sampleX)
    {
        for (int sampleY = 0; sampleY < 4; ++sampleY)
        {
            ivec2 samplePixel = pixelBase + ivec2(sampleX, sampleY);
            bool isSky = true;
            if (!any(greaterThan(samplePixel, ubo.ubo.reblur_rect_size_minus_one[REBLUR_SIGNAL].xy)))
            {
                float viewDepth = abs(reblurFetch_reblur_SIGNAL_viewz(min(samplePixel, ubo.ubo.reblur_rect_size_minus_one[REBLUR_SIGNAL].xy)).x * ubo.ubo.reblur_view_z_scale[REBLUR_SIGNAL]);
                isSky = !(viewDepth < ubo.ubo.reblur_denoising_range[REBLUR_SIGNAL]);
            }
            skyPixelCount += int(isSky);
        }
    }
    atomicAdd(s_Sum, skyPixelCount);
    barrier();
    if (isFirstThread)
        TILE_STORE(ivec2(gl_WorkGroupID.xy), vec4(float(s_Sum == 256)));
}
'''.replace('reblur_SIGNAL_', 'reblur_'+prefix+'_').replace('TILE_STORE',tile_store)
    return source.replace('s_Sum','sharedSkyPixelCount')


def fold_shared_loads(source):
    main = source.index('void main()')
    start = re.search(r'            uint (_\d+) = gl_LocalInvocationIndex % (\d+)u;\n            uint (_\d+) = gl_LocalInvocationIndex / \2u;\n            uvec2 (_\d+) = .*;\n',source[main:])
    assert start
    begin = main+start.start()
    barrier = source.index('        barrier();',begin)
    block = source[begin:barrier]
    shared_stores=list(re.finditer(r'^\s*s_\w+\[_\d+\]\[_\d+\] = .*;\n',block,re.M))
    assert len(shared_stores) in (2,3)
    count=int(re.search(r'if \(_\d+ < (\d+)u\)',block)[1])
    body=block[start.end()-start.start():shared_stores[0].end()]
    invariants=''
    for invariant in re.findall(r'^            bool _\d+ = ubo\..*;\n',body,re.M):
        invariants+=invariant
        body=body.replace(invariant,'')
    first_names={start[1]:'sharedX',start[3]:'sharedY'}
    declarations=re.findall(r'\b(?:float|bool|vec[234]|uvec2) (_\d+)\s*[=;]',body)
    first_names.update({name:'sharedValue'+str(i) for i,name in enumerate(declarations)})
    reference=re.sub(r'\s+','',rename(body,first_names))
    for index,store in enumerate(shared_stores[1:],1):
        part=block[shared_stores[index-1].end():store.end()]
        coordinates=re.search(r'uint (_\d+) = _\d+ % \d+u;\n\s*uint (_\d+) = _\d+ / \d+u;',part)
        assert coordinates
        # Skip the conditional's opening brace; the loop bound replaces it.
        brace=part.index('{',coordinates.end())
        part=part[brace+1:]
        declarations=re.findall(r'\b(?:float|bool|vec[234]|uvec2) (_\d+)\s*[=;]',part)
        names={coordinates[1]:'sharedX',coordinates[2]:'sharedY'}
        names.update({name:'sharedValue'+str(i) for i,name in enumerate(declarations)})
        assert re.sub(r'\s+','',rename(part,names)) == reference, ('Shared load differs',index)
    origin=re.search(r'            uvec2 _\d+ = .*;\n',start[0])[0]
    loop=origin+invariants
    loop+='            for (uint sharedIndex = gl_LocalInvocationIndex; sharedIndex < '+str(count)+'u; sharedIndex += 128u)\n            {\n'
    loop+='                uint sharedX = sharedIndex % '+start[2]+'u;\n                uint sharedY = sharedIndex / '+start[2]+'u;\n'
    loop+=textwrap.indent(textwrap.dedent(rename(body,first_names)),'                ')
    loop+='            }\n        }\n'
    source=source[:begin]+loop+source[barrier:]
    if 's_Normal_HitDistForTracking' not in source:
        roles=['sharedPixel']
    elif '#define NRD_BOUNCE 1' in source:
        roles=['sharedNormalRoughness','sharedEncodedNormalX','sharedEncodedNormalY','sharedOctNormalX','sharedOctNormalY','sharedNormalUnnormalized']
    else:
        roles=['sharedPixel','sharedNormalRoughness','sharedEncodedNormalX','sharedEncodedNormalY','sharedOctNormalX','sharedOctNormalY','sharedNormalUnnormalized','sharedHitDistance','sharedHitDistanceInvalid']
    source=re.sub(r'\bsharedValue(\d+)\b',lambda m:roles[int(m[1])],source)
    names={start[4]:'sharedPixelOrigin'}
    for name in re.findall(r'bool (_\d+) = ubo\.',invariants):
        names[name]='isPrepassDisabled'
    return rename(source,names)


def name_surface_values(source):
    """Name values whose meaning follows directly from the resource/math."""
    main=source.index('void main()')
    header,body=source[:main],source[main:]
    names={}
    used=set(re.findall(r'\b[A-Za-z]\w*\b',source))
    def assign(identifier,base):
        if identifier in names:
            return
        name=base
        suffix=2
        while name in used:
            name=base+str(suffix)
            suffix+=1
        names[identifier]=name
        used.add(name)
    for pattern,role in [
        (r'ivec2 (_\d+) = ivec2\(.*gl_(?:GlobalInvocationID|WorkGroupID)', 'pixelPos'),
        (r'(?:uvec2|ivec2) (_\d+) = uvec2\(min\(', 'clampedPixel'),
        (r'vec2 (_\d+) = \(vec2\(.*?\) \+ vec2\(0\.5\)\) \* ubo\.ubo\.reblur_rect_size_inv', 'pixelUv'),
        (r'float (_\d+) = abs\(reblurFetch_(?:temporal_)?reblur_\w+_(?:viewz|depth)\(', 'viewDepth'),
        (r'vec4 (_\d+) = reblurFetch_(?:temporal_)?reblur_\w+_(?:viewz|depth)\(', 'packedViewDepth'),
        (r'vec4 (_\d+) = reblurFetch_reblur_\w+_normal\(', 'packedNormalRoughness'),
        (r'vec4 (_\d+) = reblurFetch_(?:prev_)?temporal_reblur_\w+_history\(', 'historyRadiance'),
        (r'vec4 (_\d+) = reblurFetch_reblur_\w+_work\(', 'currentRadiance'),
        (r'vec3 (_\d+) = \(_\d+ \* inversesqrt\(spvNMax\(dot\(_\d+, _\d+\)', 'normalWorld'),
        (r'vec3 (_\d+) = \(?reblurSafeNormalize\(', 'normalWorld'),
        (r'mat4 (_\d+) = transpose\(ubo\.ubo\.reblur_view_to_world', 'viewToWorld'),
        (r'bool (_\d+) = ubo\.ubo\.reblur_ortho_mode\[REBLUR_SIGNAL\] == 0\.0', 'isPerspective'),
        (r'vec4 (_\d+) = vec4\(ubo\.ubo\.reblur_rotator(?:_pre|_post)?\[REBLUR_SIGNAL\]\.xz', 'scaledRotator'),
        (r'float (_\d+) = 1\.0 / \(ubo\.ubo\.reblur_plane_dist_sensitivity', 'planeWeightScale'),
        (r'float (_\d+) = ubo\.ubo\.reblur_min_rect_dim_mul_unproject', 'frustumSize'),
        (r'bool (_\d+) = all\(lessThanEqual\(ivec3\(gl_GlobalInvocationID\)', 'isInsideRect'),
        (r'float (_\d+) = centerRadiance\.w;', 'centerHitDistance'),
        (r'vec2 (_\d+) = roundEven\(reblurFetch_reblur_\w+_scratch_0', 'accumulatedFrameCounts'),
        (r'vec2 (_\d+) = mix\(vec2\(1\.0 / \(1\.0 \+', 'nonLinearAccumulationSpeed'),
        (r'float (_\d+) = \(ubo\.ubo\.reblur_min_hit_distance_weight', 'minHitDistanceWeight'),
        (r'float (_\d+) = ubo\.ubo\.reblur_min_hit_distance_weight', 'minHitDistanceWeight'),
        (r'(?:uint|int) (_\d+) = 0; _\d+ (?:<|<=)', 'neighborIndex'),
    ]:
        for match in re.finditer(pattern,body):
            assign(match[1],role)
    # Name unpacked normal components by following the packed source.
    for packed,meaning in list(names.items()):
        if meaning.startswith('packedViewDepth'):
            match=re.search(r'float (_\d+) = '+packed+r'\.x;',body)
            if match:
                assign(match[1],'signedViewDepth')
                depth=re.search(r'float (_\d+) = abs\('+match[1]+r' \* ubo\.ubo\.reblur_view_z_scale',body)
                if depth:
                    assign(depth[1],'viewDepth')
        if not meaning.startswith('packedNormalRoughness'):
            continue
        for component,role in [('x','encodedNormalX'),('y','encodedNormalY')]:
            for match in re.finditer(r'float (_\d+) = '+packed+r'\.'+component+r';',body):
                assign(match[1],role)
    # Reconstruction produces XY first, then explicitly assigns view Z.
    for match in re.finditer(r'vec3 (_\d+) = vec3\((_[0-9]+)\.x, \2\.y, _\d+\.z\);\n\s*\1\.z = (_\d+);',body):
        assign(match[1],'positionView')
        assign(match[2],'positionViewXY')
        assign(match[3],'viewDepth')
        direction=re.search(r'(_\d+) = normalize\(-'+match[1]+r'\);',body)
        if direction:
            assign(direction[1],'viewDirection')
    for match in re.finditer(r'vec3 (_\d+) = (\w+) \* mat3\(',body):
        operand=names.get(match[2],match[2])
        if operand.startswith('normalWorld'):
            assign(match[1],'normalView')
        elif operand.startswith('positionView'):
            assign(match[1],'positionWorld')
    return header+rename(body,names)


def fold_normal_neighborhood(source,stage):
    if stage != 'temporalaccumulation':
        return source
    # Exact 2x2 normal average, with the original left-to-right additions.
    average=re.search(r'^( +)vec3 (_\d+) = .*s_Normal_HitDistForTracking.*\* 0\.25.*;\n',source,re.M)
    assert average and average[0].count('* 0.25')==4
    code=average[1]+'vec3 '+average[2]+' = s_Normal_HitDistForTracking[gl_LocalInvocationID.y][gl_LocalInvocationID.x].xyz * 0.25;\n'
    code+=average[1]+'for (int normalTap = 1; normalTap < 4; ++normalTap)\n'+average[1]+'{\n'
    code+=average[1]+'    ivec2 sharedNormalPixel = ivec2(gl_LocalInvocationID.xy) + ivec2(normalTap & 1, normalTap >> 1);\n'
    code+=average[1]+'    '+average[2]+' += s_Normal_HitDistForTracking[sharedNormalPixel.y][sharedNormalPixel.x].xyz * 0.25;\n'+average[1]+'}\n'
    source=source.replace(average[0],code)
    minimum=re.search(r'^( +)float (_\d+) = spvNMin\(.*s_Normal_HitDistForTracking.*;\n',source,re.M)
    if minimum:
        assert minimum[0].count('spvNMin(')==9
        code=minimum[1]+'float '+minimum[2]+' = 1000000.0;\n'
        code+=minimum[1]+'for (int trackingY = 0; trackingY < 3; ++trackingY)\n'+minimum[1]+'{\n'
        code+=minimum[1]+'    for (int trackingX = 0; trackingX < 3; ++trackingX)\n'+minimum[1]+'    {\n'
        code+=minimum[1]+'        ivec2 trackingPixel = ivec2(gl_LocalInvocationID.xy) + ivec2(trackingX, trackingY);\n'
        code+=minimum[1]+'        '+minimum[2]+' = spvNMin('+minimum[2]+', s_Normal_HitDistForTracking[trackingPixel.y][trackingPixel.x].w);\n'
        code+=minimum[1]+'    }\n'+minimum[1]+'}\n'
        source=source.replace(minimum[0],code)
    return source


def recover_math_helpers(source):
    definitions=dict(re.findall(r'\bfloat (\w+) = ([^;\n]+);',source))
    candidates=set()
    def decode(match):
        indent,result,x,y,third=match.groups()
        xy=re.fullmatch(r'(\w+) - (\w+)',definitions.get(x,''))
        if not xy:
            return match[0]
        a,b=xy.groups()
        packed=re.fullmatch(r'(\w+)\.x',definitions.get(a,''))
        if not packed or definitions.get(b) != packed[1]+'.y' or definitions.get(y) != '('+a+' + '+b+') - 1.0':
            return match[0]
        # This is NRD's octahedral decode, not the engine frontend encoding.
        if 'abs('+x+')' not in third or 'abs('+y+')' not in third or 'float(' not in third:
            return match[0]
        candidates.update((x,y,a,b))
        return indent+'vec3 '+result+' = reblurDecodeNormalUnnormalized('+packed[1]+');'
    source=re.sub(r'^( +)vec3 (\w+) = vec4\((\w+), (\w+), (.*), [^,;]+\)\.xyz;',decode,source,flags=re.M)
    epsilon='9.999999717180685365747194737196e-10'
    source=re.sub(r'\b(\w+) \* inversesqrt\(spvNMax\(dot\(\1, \1\), '+re.escape(epsilon)+r'\)\)',r'reblurSafeNormalize(\1)',source)
    source=re.sub(r'mix\(1\.5675890445709228515625, 1\.39933097362518310546875, clamp\((\w+), 0\.0, 1\.0\)\) \* sqrt\(clamp\(1\.0 - \1, 0\.0, 1\.0\)\)',r'reblurNormalAngle(\1)',source)
    hash_pattern=r'^( +)uint (\w+) = \((\w+) \^ \(\3 >> 16u\)\) \* 2146121005u;\n\1uint (\w+) = \(\2 \^ \(\2 >> 15u\)\) \* 2221713035u;\n\1uint (\w+) = \4 \^ \(\4 >> 16u\);'
    source=re.sub(hash_pattern,lambda m:m[1]+'uint '+m[5]+' = reblurHash('+m[3]+');',source,flags=re.M)
    # Remove only the now-unused components of recovered oct decodes.
    while True:
        previous=source
        for name in candidates:
            if len(re.findall(r'\b'+name+r'\b',source))==1:
                source=re.sub(r'^ +float '+name+r' = [^;\n]+;\n','',source,flags=re.M)
        if source==previous:
            break
    if re.search(r'\breblur(?:DecodeNormalUnnormalized|SafeNormalize|NormalAngle|Hash)\(',source):
        index=source.index('void main()')
        source=source[:index]+'#include "filter_math.glsl"\n\n'+source[index:]
    return source


def fold_reprojected_normals(source,stage):
    if stage!='temporalaccumulation':
        return source
    pattern=r'^( +)vec4 (_\d+) = (reblurFetch_prev_temporal_reblur_\w+_normal)\(([^;]+)\);\n\1vec3 (_\d+) = reblurDecodeNormalUnnormalized\(\2\);\n'
    samples=list(re.finditer(pattern,source,re.M))
    # The surface-motion bilinear footprint precedes the specular virtual one.
    if len(samples)<4:
        raise AssertionError('Missing previous-normal footprint')
    samples=samples[:4]
    assert all(a.end()==b.start() for a,b in zip(samples,samples[1:]))
    base=samples[0][4]
    expected=[base,'('+base+')+(ivec2(1, 0))','('+base+')+(ivec2(0, 1))','('+base+')+(ivec2(1))']
    assert [m[4] for m in samples]==expected
    assert all(m[3]==samples[0][3] for m in samples)
    for m in samples:
        assert len(re.findall(r'\b'+m[2]+r'\b',source))==2
    indent=samples[0][1]
    loop=indent+'vec3 previousNormalsUnnormalized[4];\n'
    loop+=indent+'for (int reprojectionTap = 0; reprojectionTap < 4; ++reprojectionTap)\n'+indent+'{\n'
    loop+=indent+'    ivec2 previousNormalPixel = '+base+' + ivec2(reprojectionTap & 1, reprojectionTap >> 1);\n'
    loop+=indent+'    vec4 previousPackedNormal = '+samples[0][3]+'(previousNormalPixel);\n'
    loop+=indent+'    previousNormalsUnnormalized[reprojectionTap] = reblurDecodeNormalUnnormalized(previousPackedNormal);\n'+indent+'}\n'
    source=source[:samples[0].start()]+loop+source[samples[-1].end():]
    return rename(source,{m[5]:'previousNormalsUnnormalized['+str(i)+']' for i,m in enumerate(samples)})


def remove_unused_numeric_values(source):
    # These are pure SSA expressions; retain atomic operations and all stores.
    while True:
        removed=False
        for match in re.finditer(r'^ +(?:float|u?int|vec[234]|ivec[234]|uvec[234]) (_\d+) = ([^;\n]+);\n',source,re.M):
            if 'atomic' in match[2].lower():
                continue
            if len(re.findall(r'\b'+match[1]+r'\b',source))==1:
                source=source[:match.start()]+source[match.end():]
                removed=True
                break
        if not removed:
            return source


def prune_helpers(source):
    # Remove unused generated image-access helpers, including their bodies.
    # Repeat because removing a sampler wrapper may orphan its load helper.
    while True:
        removed=False
        for match in re.finditer(r'^(?:void|[ui]?vec4) (reblur(?:Fetch|Nearest|Linear|Gather|Store|UintLoad)_\w+)\([^;\n]*\)\s*\{',source,re.M):
            depth=1
            end=match.end()
            while depth:
                depth+=(source[end]=='{')-(source[end]=='}')
                end+=1
            rest=source[:match.start()]+source[end:]
            if not re.search(r'\b'+match[1]+r'\s*\(',rest):
                source=rest
                removed=True
                break
        if not removed:
            return re.sub(r'\n(?:[ \t]*\n){2,}', '\n\n',source)


def name_bounce_temporal(source):
    # Full data-flow map for the diffuse temporal kernel, including the
    # 12-tap disocclusion footprint and five-fetch Catmull-Rom reconstruction.
    names={
        '_178':'unusedRadiancePadding','_179':'unusedPositionPadding',
        '_180':'unusedNormalPadding','_181':'unusedHistoryPadding',
        '_193':'tileClassification','_194':'tileIsSky',
        '_287':'skipPixel','_290':'outputPixel',
        '_402':'screenMotionUv','_438':'screenMotionWithDepth',
        '_437':'inferredDepthMotion','_454':'previousWorldToView',
        '_409':'worldMotionPosition','_416':'worldMotionClipPosition',
        '_472':'previousPixelPosition','_473':'previousPixelFloor',
        '_477':'previousGatherUv',
        '_496':'previousDepthUpperLeft','_499':'previousDepthUpperRight',
        '_502':'previousDepthLowerLeft','_505':'previousDepthLowerRight',
        '_507':'bilinearFraction','_512':'previousNormalOrigin',
        '_622':'perspectiveMask','_632':'forwardParallaxClip',
        '_650':'backwardParallaxClip','_660':'maxParallaxPixels',
        '_664':'projectionDepthScale','_671':'isStrandMaterial',
        '_680':'strandThresholdBlend','_685':'materialDisocclusionThreshold',
        '_688':'strandParallaxBlend','_694':'disocclusionThreshold',
        '_698':'normalRejectionAngle',
        '_721':'bilinearPixelBounds','_728':'bilinearBoundsValid',
        '_741':'disocclusionPlaneThresholds',
        '_750':'expectedPreviousViewDepth','_762':'denoisingRangeVector',
        '_787':'packedStateUpperLeft','_791':'packedStateUpperRight',
        '_795':'packedStateLowerLeft','_799':'packedStateLowerRight',
        '_801':'historyStateChannelMax','_802':'historyStateChannelScale',
        '_823':'historyStateTopLeft','_840':'historyStateTopRight',
        '_865':'historyStateBottomLeft','_882':'historyStateBottomRight',
        '_906':'minComparableMaterial','_908':'comparableMaterialVector',
        '_909':'minComparableMaterialVector',
        '_913':'validHistoryUpperLeft','_917':'validHistoryUpperRight',
        '_921':'validHistoryLowerLeft','_925':'validHistoryLowerRight',
        '_931':'bilinearFractionComplement','_932':'bilinearLeftWeight',
        '_933':'bilinearTopWeight','_936':'bilinearRightWeight',
        '_939':'bilinearBottomWeight',
        '_935':'historyWeightTopLeft','_938':'historyWeightTopRight',
        '_941':'historyWeightBottomLeft','_943':'historyWeightBottomRight',
        '_944':'bilinearHistoryWeights','_950':'allowCatmullRom',
        '_985':'hasNoHistoryWeight','_990':'inverseHistoryWeightSum',
        '_991':'reprojectedFrameCount','_1020':'packedZeroCurvature',
        '_1027':'confidenceAdjustedFrameCount',
        '_1031':'historySamplePixel','_1036':'historySampleCenter',
        '_1038':'historySampleFraction',
        '_1043':'catmullRomOuterLeftWeights','_1053':'catmullRomInnerRightWeights',
        '_1057':'catmullRomOuterRightWeights','_1058':'catmullRomInnerWeightSum',
        '_1059':'catmullRomInnerOffset','_1060':'catmullRomInnerWeightX',
        '_1064':'catmullRomInnerWeightY',
        '_1073':'historyReconstructionWeights','_1074':'historyReconstructionLastWeight',
        '_1076':'historyReconstructionWeightSum','_1077':'historySampleCenterPairs',
        '_1084':'historyFetchOffsetsFirstPair','_1092':'historyFetchOffsetsSecondPair',
        '_1099':'historyFetchOffsetLast','_1102':'historyFetchUvsFirstPair',
        '_1103':'historyFetchUvsSecondPair','_1147':'reprojectedHistoryYCoCg',
        '_1148':'fastHistoryPixelOrigin','_1168':'reprojectedFastLuminance',
        '_1171':'historyYMinusCg','_1178':'historyRadianceRgb',
        '_1179':'historyLuminance','_1184':'historyNormalizedHitDistance',
        '_1187':'currentFrameWeight','_1191':'accumulatedRadianceYCoCg',
        '_1199':'accumulatedHitDistance','_1202':'accumulatedFrameCount',
        '_1208':'fireflySuppressionSpeed','_1210':'fireflySuppressionStrength',
        '_1211':'accumulatedLuminance','_1212':'fireflyLuminanceLimit',
        '_1218':'suppressedRadianceYCoCg','_1219':'outputRadianceAndHitDistance',
        '_1233':'accumulatedFastLuminance','_1241':'unusedSpecularFrameCount',
    }
    remaining=set(re.findall(r'\b_\d+\b',source))
    assert remaining<=names.keys(), ('Unmapped bounce temporaries',remaining-names.keys())
    # Verify the edit is only a bijective identifier substitution.
    active={key:value for key,value in names.items() if key in remaining}
    assert len(set(active.values()))==len(active)
    assert all(not re.search(r'\b'+value+r'\b',source) for value in active.values())
    named=rename(source,active)
    inverse={value:key for key,value in active.items()}
    assert re.sub(r'\b\w+\b',lambda m:inverse.get(m[0],m[0]),named)==source
    # SPIRV-Cross emitted undefined padding that is overwritten immediately.
    # Remove only these discarded components, not any observable calculation.
    named=named.replace('unusedPositionPadding.z','0.0').replace('unusedRadiancePadding.w','0.0')
    named=re.sub(r'^(?:vec[34]|float) unused(?:Radiance|Position|Normal|History)Padding;\n','',named,flags=re.M)
    for anchor,comment in [
        ('vec4 tileClassification =','Cooperative normal preload; every thread reaches the barrier.'),
        ('vec3 motionVector =','Reconstruct previous position from screen-space or world-space motion.'),
        ('vec2 previousPixelPosition =','Previous-frame footprint: four bilinear taps inside a 12-tap validity stencil.'),
        ('vec4 disocclusionPlaneThresholds =','Reject history by normal agreement, screen bounds, plane depth and material.'),
        ('vec2 historySamplePixel =','Use five-fetch Catmull-Rom only when the full footprint is valid; otherwise bilinear.'),
        ('float historyYMinusCg =','Decode history, accumulate radiance/hit distance, then apply firefly suppression.'),
    ]:
        named=named.replace('        '+anchor,'        // '+comment+'\n        '+anchor)
    return named


def name_remaining_values(source,stage):
    signal='bounce' if '#define NRD_BOUNCE 1' in source else 'reflection'
    remaining=set(re.findall(r'\b_\d+\b',source))
    if not remaining:
        return source
    # Audited names for the pinned kernels, not guesses from storage types.
    table=json.loads(Path(__file__).with_name('semantic_names.json').read_text())
    names=table[signal+'_'+stage]
    assert remaining==names.keys(),(signal,stage,remaining-names.keys(),names.keys()-remaining)
    assert len(set(names.values()))==len(names)
    assert all(not re.search(r'\b'+name+r'\b',source) for name in names.values()),(signal,stage,'Name collision')
    result=rename(source,names)
    inverse={name:identifier for identifier,name in names.items()}
    # This cleanup must change identifiers only, including phi/carry values.
    assert re.sub(r'\b\w+\b',lambda m:inverse.get(m[0],m[0]),result)==source
    if signal=='reflection' and stage=='temporalaccumulation':
        normal_names={'normalWorld':'virtualNormalWorldTopLeft',
                      'normalWorld2':'virtualNormalWorldTopRight',
                      'normalWorld3':'virtualNormalWorldBottomLeft',
                      'normalWorld4':'virtualNormalWorldBottomRight',
                      'normalWorld5':'reprojectedVirtualNormalWorld'}
        result=re.sub(r'\bnormalWorld\d*\b',lambda m:normal_names[m[0]],result)
    return result


def restore(source, stage):
    # Loop nesting is preserved by DXC even when the carried SSA values are not.
    if stage=='historyfix':
        loop_names={}
        for lower,prefix in [('-2','repair'),('-4','statistics')]:
            counters=re.findall(r'for \(int (_\d+) = '+lower+r';',source)
            assert len(counters)==2
            loop_names.update(zip(counters,[prefix+'Y',prefix+'X']))
        source=rename(source,loop_names)
    if stage == 'prepare':
        # This kernel comes from our frontend.hlsl, so its data flow is known.
        source=rename(source,{
            '_86':'isDiffuse','_94':'sourcePixel','_96':'surfacePosition',
            '_101':'encodedShadingNormal','_102':'octNormalX','_105':'octNormalY',
            '_107':'octNormalZ','_108':'unfoldedNormal','_120':'foldedNormalXY',
            '_122':'shadingNormal','_129':'roughness','_142':'viewDepth',
            '_144':'sampleRay','_151':'hitDistance','_154':'incidentRadiance',
            '_162':'shadedRadiance','_163':'clampedRadiance','_177':'normalizedHitDistance',
            '_187':'octNormal','_190':'packedNormalY','_192':'packedNormalX',
            '_195':'clampedRoughness','_202':'signedRoughness',
            '_205':'encodedNormalRoughness','_206':'packedNormalRoughness',
            '_229':'invalidRadiance','_234':'finiteRadiance',
            '_240':'invalidHitDistance','_245':'finiteHitDistance','_255':'packedSignal',
        })
    if stage == 'classifytiles':
        source = classify_tiles(source)
    if stage in ('blur','postblur','prepass'):
        source = fold_spatial(source)
    if stage in ('historyfix','temporalaccumulation','temporalstabilization'):
        source = fold_shared_loads(source)
    source=fold_normal_neighborhood(source,stage)
    if stage=='temporalaccumulation':
        if '#define NRD_BOUNCE 1' in source:
            contextual={
                '_362':'averagedNormalWorld','_383':'materialId',
                '_384':'normalWorldUnnormalized','_389':'surfaceNormalWorld','_400':'motionVector',
                '_467':'previousPositionWorld','_468':'surfaceMotionUv',
                '_711':'viewDirectionWorld','_713':'absNormalDotView',
                '_1000':'previousViewDirectionWorld','_1005':'normalDotViewRatio',
                '_984':'surfaceHistoryWeightSum',
            }
        else:
            contextual={
                '_458':'viewToWorldRotation','_459':'positionWorld',
                '_502':'averagedNormalWorld','_532':'minTrackingHitDistance',
                '_554':'materialId','_559':'normalizedSurfaceNormalWorld',
                '_560':'surfaceNormalWorld','_662':'motionVector',
                '_729':'previousPositionWorld','_730':'surfaceMotionUv',
                '_908':'surfaceForwardParallaxPixels','_926':'surfaceBackwardParallaxPixels',
                '_927':'maxSurfaceParallaxPixels','_928':'minSurfaceParallaxPixels',
                '_650':'hitDistanceForTracking','_979':'viewDirectionWorld',
                '_981':'absNormalDotView','_1250':'surfaceHistoryWeightSum',
                '_1266':'previousViewDirectionWorld','_1271':'normalDotViewRatio',
                '_1310':'neighborViewDirectionX','_1342':'neighborViewDirectionY',
                '_1367':'estimatedNeighborPositionWorld','_1370':'interpolatedNeighborNormalWorld',
                '_1374':'estimatedNeighborNormalWorld','_1415':'sampledNeighborPositionWorld',
                '_1496':'neighborNormalWorld','_1497':'neighborPositionWorld',
                '_1498':'surfaceEdgeWorld','_1504':'curvature',
            }
        source=rename(source,contextual)
    source=fold_reprojected_normals(recover_math_helpers(source),stage)
    source=prune_helpers(name_surface_values(remove_unused_numeric_values(source)))
    if stage=='temporalaccumulation' and '#define NRD_BOUNCE 1' in source:
        source=name_bounce_temporal(source)
    return name_remaining_values(source,stage)
