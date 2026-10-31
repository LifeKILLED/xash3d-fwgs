#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

typedef uint32_t uint;
#define RIS_INVALID_LIGHT_ID UINT32_MAX
static uint light_hashes[] = {10u, 20u, 30u, 40u, 50u};
static uint light_count = 5u;
static bool testSlotValid(uint id) { return id < light_count; }
static bool testHashMatches(uint id, uint hash) {
    return testSlotValid(id) && light_hashes[id] == hash;
}
#define RIS_ID_RECOVERY_FUNCTION recoverLightId
#define RIS_ID_RECOVERY_HASH_MATCHES testHashMatches
#define RIS_ID_RECOVERY_SLOT_VALID testSlotValid
// Exercise the exact recovery algorithm instantiated by point/poly GLSL.
#include "../shaders/light_id_recovery.glsl"

int main(void) {
    assert(recoverLightId(2u, 30u) == 2u); // Existing matching slot wins.
    assert(recoverLightId(2u, 40u) == 3u); // Shift forward by one.
    assert(recoverLightId(2u, 20u) == 1u); // Shift backward by one.
    assert(recoverLightId(2u, 999u) == 2u); // Moving/changing light retains ID.
    assert(recoverLightId(2u, 50u) == 2u); // No recovery from distance two.
    assert(recoverLightId(0u, 20u) == 1u); // First slot has no -1 neighbor.
    assert(recoverLightId(4u, 40u) == 3u); // Last slot has no +1 neighbor.
    assert(recoverLightId(5u, 50u) == 4u); // Deleted tail recovers shifted source.
    assert(recoverLightId(5u, 999u) == RIS_INVALID_LIGHT_ID); // No valid fallback.
    light_hashes[1] = light_hashes[3] = 77u;
    assert(recoverLightId(2u, 77u) == 3u); // Deterministic +1 priority.
    light_hashes[2] = 77u;
    assert(recoverLightId(2u, 77u) == 2u); // Current wins even with matching neighbors.
    assert(recoverLightId(RIS_INVALID_LIGHT_ID, 77u) == RIS_INVALID_LIGHT_ID);
    light_count = 0u;
    assert(recoverLightId(0u, 10u) == RIS_INVALID_LIGHT_ID);
    puts("Light ID recovery checks passed");
    return 0;
}
