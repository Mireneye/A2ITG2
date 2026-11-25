# Copied code

Code copied from other Mirage projects. The copies are allowed to drift; when the originals improve
(a TLS fix, a faster inflate), copy them again on purpose and re-apply the changes listed here.

| Here | Copied from | At commit | A2ITG2 changes |
|---|---|---|---|
| `src/tls/` | WeavingMirage `src/tls/` | `6e4cf84` | `trust_other.odin`: Android reads its root certificates from `/apex/com.android.conscrypt/cacerts` (Android 14+) or `/system/etc/security/cacerts` |
| `src/inflate/inflate.odin` | FoldingMirage `src/core/inflate.odin` | `2d87f16` | `package inflate` instead of `package core`; `cpu_has_bmi2` only asks the CPU on x86 (ARM phones take the generic path) |

To update: copy the files over, re-apply the changes in the last column, and run `odin test src/tls`.
