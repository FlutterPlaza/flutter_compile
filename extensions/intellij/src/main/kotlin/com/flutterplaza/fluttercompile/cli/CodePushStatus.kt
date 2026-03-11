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
)

/** A single Code Push patch under a release. */
data class CodePushPatch(
    val number: Int,
    val rollout: Int = 100,
    val active: Boolean = true,
    val created_at: String? = null,
)

/** Code Push app status returned by `flutter_compile codepush status --json`. */
data class CodePushAppStatus(
    val configured: Boolean = false,
    val app_id: String? = null,
    val app_name: String? = null,
    val releases: List<CodePushRelease>? = null,
)

/** Code Push patches for a release returned by `flutter_compile codepush status --json --release-id <id>`. */
data class CodePushPatchesResponse(
    val release_id: String? = null,
    val patches: List<CodePushPatch>? = null,
)
