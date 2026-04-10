package com.flutterplaza.fluttercompile.cli

/** Account info returned by `flutter_compile codepush account --json`. */
data class CodePushAccount(
    val email: String? = null,
    val tier: String? = null,
    val logged_in: Boolean = false,
)

/** A single Code Push release. */
data class CodePushRelease(
    val id: String,
    val version: String,
    val platform: String? = null,
    val created_at: String? = null,
    val patch_count: Int = 0,
)

/** A single Code Push patch under a release. */
data class CodePushPatch(
    val id: String? = null,
    val number: Int = 0,
    val rollout_percentage: Int = 100,
    val is_active: Boolean = true,
    val created_at: String? = null,
) {
    /** Convenience alias matching the server JSON field. */
    val rollout: Int get() = rollout_percentage
    val active: Boolean get() = is_active
}

/** Code Push app status returned by `flutter_compile codepush status --json`. */
data class CodePushAppStatus(
    val configured: Boolean = false,
    val logged_in: Boolean = false,
    val app_id: String? = null,
    val app_name: String? = null,
    val releases: List<CodePushRelease>? = null,
    val total_patches: Int = 0,
)

/** A single supported Flutter version returned by `codepush versions --json`. */
data class CodePushVersionEntry(
    val version: String,
    val build_revision: String? = null,
    val installed: Boolean = false,
    val global: Boolean = false,
    val project_pinned: Boolean = false,
)

/** Response returned by `flutter_compile codepush versions --json`. */
data class CodePushVersionsResponse(
    val selected: String? = null,
    val versions: List<CodePushVersionEntry>? = null,
    val error: String? = null,
)

/** Code Push patches for a release returned by `flutter_compile codepush status --json --release-id <id>`. */
data class CodePushPatchesResponse(
    val release_id: String? = null,
    val patches: List<CodePushPatch>? = null,
)
