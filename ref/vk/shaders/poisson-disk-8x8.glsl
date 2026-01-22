
float getPoissonCoord(uint index) {
    const float poisson8x8coordinates[128] = float[128](
        0.814721f, 0.229983f,
        -0.023665f, 0.850224f,
        0.532795f, 0.240577f,
        -0.668997f, -0.704339f,
        0.417544f, -0.514182f,
        -0.411010f, -0.535333f,
        0.649455f, -0.652109f,
        -0.987766f, -0.759248f,
        -0.108909f, -0.635039f,
        -0.850402f, 0.144311f,
        0.408706f, -0.888395f,
        -0.435589f, 0.646887f,
        0.667034f, 0.493170f,
        -0.541848f, 0.947954f,
        0.219410f, 0.287589f,
        -0.357385f, 0.349158f,
        0.607231f, -0.314974f,
        0.718270f, 0.928703f,
        0.382475f, 0.025372f,
        -0.875111f, -0.542110f,
        0.308682f, -0.222126f,
        -0.911368f, -0.315838f,
        0.216250f, -0.680707f,
        0.921618f, 0.700052f,
        -0.208863f, -0.988900f,
        -0.675749f, -0.113037f,
        -0.687101f, 0.681087f,
        0.830954f, -0.894942f,
        -0.183986f, 0.604690f,
        0.921077f, 0.464601f,
        -0.279616f, 0.918157f,
        -0.417791f, 0.038245f,
        0.210881f, 0.985942f,
        0.649495f, -0.046090f,
        0.444899f, 0.993442f,
        0.120160f, -0.426651f,
        -0.974727f, -0.989687f,
        -0.366550f, -0.214272f,
        0.000912f, -0.850014f,
        0.923523f, -0.195705f,
        -0.179853f, 0.063389f,
        -0.362236f, -0.794263f,
        -0.667265f, 0.418907f,
        0.935893f, 0.039505f,
        0.083752f, 0.557828f,
        -0.992595f, 0.733591f,
        0.282777f, 0.736459f,
        -0.984157f, -0.105092f,
        0.580709f, 0.724475f,
        0.968797f, -0.621186f,
        0.108394f, 0.043343f,
        0.194042f, -0.993501f,
        -0.620389f, -0.385276f,
        0.865289f, -0.424623f,
        -0.175333f, -0.388006f,
        0.615041f, -0.966167f,
        -0.023990f, -0.178335f,
        -0.594574f, -0.948160f,
        -0.601990f, 0.182024f,
        0.983671f, 0.930902f,
        -0.071478f, 0.315076f,
        -0.821980f, 0.901983f,
        0.385238f, 0.489848f,
        -0.939316f, 0.509421f
    );

    return poisson8x8coordinates[index];
}

uint getPoissonNeighborEncoded(uint index) {
    const uint poisson8x8neighboors[128] = uint[128](
        612409806u, 278301692u,
        470585073u, 632482635u,
        613812207u, 274260433u,
        508841191u, 232221739u,
        497691058u, 1066651968u,
        219903326u, 399981049u,
        267671745u, 502474880u,
        916221168u, 390943006u,
        78208481u, 972828018u,
        351892684u, 517057961u,
        26947581u, 574007521u,
        784704052u, 212964926u,
        522867152u, 239455784u,
        137315953u, 441706042u,
        789497253u, 142681866u,
        690008876u, 151995582u,
        1014255716u, 708377574u,
        547542736u, 530035164u,
        294740637u, 712921250u,
        326658806u, 362639664u,
        378018479u, 182397186u,
        727575763u, 216285766u,
        1057102465u, 1037949325u,
        277055175u, 472537951u,
        1067243605u, 14445700u,
        911002206u, 303251017u,
        347858507u, 137565882u,
        83950013u, 1020000385u,
        745111755u, 299034417u,
        272234536u, 613910218u,
        874559022u, 476680443u,
        442471564u, 519578220u,
        269322029u, 539123249u,
        1009314786u, 537155423u,
        410062395u, 60950245u,
        232531826u, 797534273u,
        365717995u, 332679094u,
        387050985u, 708100242u,
        365646719u, 18053760u,
        260718926u, 19593631u,
        962079529u, 390558490u,
        104231221u, 969797089u,
        191450380u, 140942985u,
        169758495u, 683542661u,
        625394204u, 382054104u,
        788219476u, 449102411u,
        759183739u, 149029976u,
        516780662u, 961800780u,
        632670264u, 183349736u,
        586311877u, 244318333u,
        743109698u, 923706013u,
        1037510720u, 363487309u,
        970667460u, 363150790u,
        614084367u, 1031156609u,
        705703501u, 701048158u,
        855533760u, 579097537u,
        491433430u, 741800569u,
        735511878u, 557182148u,
        392732585u, 189615698u,
        538775080u, 999671789u,
        138688146u, 36592214u,
        189984058u, 208178302u,
        271189777u, 763284419u,
        422006714u, 325771980u
    );

    return poisson8x8neighboors[index];
}

// Decode 6-bit index from uint
uint get6bitIndex(uint packed, int i) {
    return (packed >> (i * 6)) & 0x3Fu;
}

// Convert ivec2 (0-7,0-7) to 0-63 index using bitshift
int texelToIndex(ivec2 texel) {
    return (texel.y << 3) | texel.x; // y*8 + x
}

// Get poisson coordinate for texel
vec2 getPoissonCoord(ivec2 texel) {
    int idx = texelToIndex(texel);
    int base = idx << 1; // idx*2
    return vec2(getPoissonCoord(base), getPoissonCoord(base+1));
}

// Get coordinate of a single neighbor
vec2 getPoissonNeighbor(ivec2 texel, int neighborIdx) {
    int idx = texelToIndex(texel);
    uint packed = getPoissonNeighborEncoded((idx<<1) + (neighborIdx<5?0:1));
    int localIdx = neighborIdx < 5 ? neighborIdx : neighborIdx - 5;
    uint neighbor = get6bitIndex(packed, localIdx);
    int base = int(neighbor) << 1; // neighbor*2
    return vec2(getPoissonCoord(base), getPoissonCoord(base+1));
}

// Get all 10 neighbors as an array
vec2[10] getPoissonNeighbors(ivec2 texel) {
    vec2 neighbors[10];
    uint idx = texelToIndex(texel);
    for(int i=0;i<10;i++){
        uint packed = getPoissonNeighborEncoded((idx<<1) + (i<5?0:1));
        int localIdx = i<5 ? i : i-5;
        uint neighbor = get6bitIndex(packed, localIdx);
        int base = int(neighbor) << 1; // neighbor*2
        neighbors[i] = vec2(getPoissonCoord(base), getPoissonCoord(base+1));
    }
    return neighbors;
}
