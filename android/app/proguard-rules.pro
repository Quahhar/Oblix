# All five ML Kit text-recognition models — Latin, Chinese, Devanagari,
# Japanese, Korean — are bundled by app/build.gradle.kts, so R8 can resolve
# every recognizer class the plugin references and no -dontwarn is needed.
#
# The four non-Latin artifacts used to be omitted and silenced here. They are
# bundled now because `api/script.rs` reads a page with more than one model and
# scores the results against each other, which only works if the models are
# present. Dropping one again means restoring its -dontwarn line, and means
# that script becomes unreadable rather than merely unchosen.
