"""Generate joint_uv_128.png from scratch; no input images.
Offline dependencies: numpy, scipy, pillow, numba. No runtime dependencies.
Joint visibility-error optimization inspired by BNDS pixel swaps, with a
training objective in both square UV and sqrt-barycentric domains.
"""
from pathlib import Path
import numpy as np
from PIL import Image
from numba import njit
from scipy.ndimage import gaussian_filter

SIDE = 128
SEED = 20261110
ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "ref/vk/data/valve/bluenoise2d/joint_uv_128.png"


def tests(rg, seed, count):
    rng = np.random.default_rng(seed)
    uv = (rg.astype(np.float64) + .5) / 256
    r = np.sqrt(uv[:,0])
    bary = np.column_stack((r*(1-uv[:,1]), r*uv[:,1]))
    result = np.zeros((len(rg),count), dtype=np.bool_)
    for i in range(count):
        points = bary if i % 2 == 0 else uv
        angle = rng.uniform(0,2*np.pi)
        projection = points @ np.array([np.cos(angle),np.sin(angle)])
        result[:,i] = projection < np.quantile(projection,rng.uniform(.01,.99))
    return result


def pack(functions):
    result = np.zeros(len(functions),dtype=np.uint64)
    for i in range(64): result |= functions[:,i].astype(np.uint64) << np.uint64(i)
    return result


@njit
def popcount(x):
    x = x - ((x >> np.uint64(1)) & np.uint64(0x5555555555555555))
    x = (x & np.uint64(0x3333333333333333)) + ((x >> np.uint64(2)) & np.uint64(0x3333333333333333))
    x = (x + (x >> np.uint64(4))) & np.uint64(0x0f0f0f0f0f0f0f0f)
    return np.int64((x * np.uint64(0x0101010101010101)) >> np.uint64(56))


@njit
def optimize(bits, neighbors, weights, attempts, seed):
    np.random.seed(seed)
    order = np.arange(len(bits))
    for iteration in range(attempts):
        a = np.random.randint(len(bits)); b = np.random.randint(len(bits))
        if a == b: continue
        va = bits[a]; vb = bits[b]; delta = 0.
        for k in range(len(weights)):
            n = neighbors[a,k]
            if n != b:
                delta += weights[k]*(popcount(va ^ bits[n])-popcount(vb ^ bits[n]))
            n = neighbors[b,k]
            if n != a:
                delta += weights[k]*(popcount(vb ^ bits[n])-popcount(va ^ bits[n]))
        delta /= 64.
        temperature = .03 * (.003 ** (iteration / attempts))
        if delta <= 0 or np.random.random() < np.exp(-delta / temperature):
            bits[a] = vb; bits[b] = va
            order[a],order[b] = order[b],order[a]
    return order


def measure(rg):
    masks = tests(rg, 991237, 256)
    result = []
    for sigma in (1.,2.,4.):
        values = masks[:,::2].T.reshape(128,SIDE,SIDE).astype(float)
        target = values.mean(axis=(1,2),keepdims=True)
        blurred = gaussian_filter(values,sigma=(0,sigma,sigma),mode="wrap")
        result.append(float(np.sqrt(np.mean((blurred**2.2-target**2.2)**2))))
    return np.array(result)


def main():
    rng = np.random.default_rng(SEED)
    yy,xx = np.indices((SIDE,SIDE))
    # One point per 1/128-square stratum. Independent binary jitter fills the
    # two possible 8-bit bins per dimension; shuffle whole sample pairs.
    rg = np.stack((2*xx+rng.integers(0,2,xx.shape),
                   2*yy+rng.integers(0,2,yy.shape)),axis=-1).reshape(-1,2).astype(np.uint8)
    rg = rg[rng.permutation(len(rg))]
    blue = np.tile(np.arange(256,dtype=np.uint8),64)
    rng.shuffle(blue)
    offsets = [(y,x) for y in range(-5,6) for x in range(-5,6) if 0<x*x+y*y<=25]
    neighbors = np.stack([(((yy+y)%SIDE)*SIDE+(xx+x)%SIDE).ravel()
                          for y,x in offsets],axis=1).astype(np.int32)
    weights = np.array([np.exp(-(x*x+y*y)/2.1**2) for y,x in offsets])
    before = measure(rg)
    print("Optimizing newly generated joint UV pairs...",flush=True)
    order = optimize(pack(tests(rg,471182,64)),neighbors,weights,12000000,SEED)
    optimized = rg[order]
    print("Optimizing independently generated scalar selector...",flush=True)
    scalar_tests = blue[:,None] < (np.arange(64)[None,:]*4+2)
    order_b = optimize(pack(scalar_tests),neighbors,weights,6000000,SEED+1)
    after = measure(optimized)
    print("Held-out gamma barycentric RMSE, sigma 1/2/4:",after,flush=True)
    print("Relative to unoptimized stratified samples:",after/before,flush=True)
    assert np.all(after < before), "Held-out validation failed"
    assert np.array_equal(np.sort(rg[:,0].astype(np.uint16)*256+rg[:,1]),
                          np.sort(optimized[:,0].astype(np.uint16)*256+optimized[:,1]))
    image = np.empty((SIDE*SIDE,4),dtype=np.uint8)
    image[:,:2] = optimized; image[:,2] = blue[order_b]; image[:,3] = 255
    Image.fromarray(image.reshape(SIDE,SIDE,4)).save(OUTPUT)
    print("Saved",OUTPUT,flush=True)

if __name__ == "__main__": main()
