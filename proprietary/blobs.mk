# Placeholder for the generated blob copy rules.
#
# tools/import-dump.sh runs tools/generate-blobs-mk.sh after importing a phone
# dump and replaces this file with rules for the files that actually exist.
# Keeping a comment-only file in Git lets a Stage 1 build (vendor_boot platform
# fragment only, no touch/KeyMint blobs) configure and compile.
