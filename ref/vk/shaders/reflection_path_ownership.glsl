#ifndef REFLECTION_PATH_OWNERSHIP_GLSL_INCLUDED
#define REFLECTION_PATH_OWNERSHIP_GLSL_INCLUDED

// Compare sample identity, not just source pixel: retreat can read different
// historical texels that already contain copies of the same selected path.
bool reflectionPathSameSource(float u, float v, float other_u, float other_v)
{
	return u == other_u && v == other_v;
}

bool reflectionPathOwnerLess(uint key, int x, int y, uint other_key, int other_x, int other_y)
{
	if (key != other_key)
		return key < other_key;
	return y < other_y || (y == other_y && x < other_x);
}

#endif
