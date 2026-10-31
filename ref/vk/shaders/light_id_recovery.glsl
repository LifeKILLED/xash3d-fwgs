// Intentionally unguarded: instantiate for each light array via these macros.
// Hash is an array-shift hint, not a validity gate for a changing light.
uint RIS_ID_RECOVERY_FUNCTION(uint original_id, uint stored_hash)
{
    if (original_id == RIS_INVALID_LIGHT_ID) return RIS_INVALID_LIGHT_ID;
    if (RIS_ID_RECOVERY_HASH_MATCHES(original_id, stored_hash)) return original_id;
    // Check +1 first, then -1. Never search beyond immediate neighbors.
    if (original_id + 1u > original_id &&
        RIS_ID_RECOVERY_HASH_MATCHES(original_id + 1u, stored_hash)) return original_id + 1u;
    if (original_id > 0u &&
        RIS_ID_RECOVERY_HASH_MATCHES(original_id - 1u, stored_hash)) return original_id - 1u;
    // An existing slot remains usable even if the source moved/changed hash.
    return RIS_ID_RECOVERY_SLOT_VALID(original_id) ? original_id : RIS_INVALID_LIGHT_ID;
}
#undef RIS_ID_RECOVERY_FUNCTION
#undef RIS_ID_RECOVERY_HASH_MATCHES
#undef RIS_ID_RECOVERY_SLOT_VALID
