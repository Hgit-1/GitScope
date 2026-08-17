# Kerberos/SPNEGO is an optional JGit HTTP authentication path that Android
# does not provide. GitScope supports token/basic HTTPS authentication only.
-dontwarn org.ietf.jgss.**

# Optional JGit Amazon S3 walk encryption; GitScope accepts HTTPS Git remotes
# only and never constructs this transport.
-dontwarn javax.xml.bind.DatatypeConverter

# This parser contains the Android-specific pack persistence patch assembled
# by build.gradle.kts. Keep it intact so R8 cannot inline or vertically merge
# the patched file-move path back into the generic JGit storage pipeline.
-keep class org.eclipse.jgit.internal.storage.file.ObjectDirectoryPackParser { *; }
-keep class org.eclipse.jgit.util.FileUtils { *; }
-keep class org.eclipse.jgit.util.FS_POSIX { *; }
-keep class org.eclipse.jgit.internal.storage.file.WindowCache { *; }
-keep class org.eclipse.jgit.storage.file.WindowCacheStats { *; }
-keep class org.eclipse.jgit.util.StringUtils { *; }

# JGit creates translation bundles reflectively, then uses the original class
# and public field names to locate and inject matching *.properties entries.
# Obfuscating or vertically merging these classes causes InstantiationException.
-keep class ** extends org.eclipse.jgit.nls.TranslationBundle { *; }

# Keep diagnostic exception names readable in on-device support codes.
-keepnames class org.eclipse.jgit.errors.**
-keepnames class org.eclipse.jgit.api.errors.**
