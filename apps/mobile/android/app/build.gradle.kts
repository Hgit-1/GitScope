import org.gradle.api.tasks.compile.JavaCompile
import org.gradle.jvm.tasks.Jar

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

val jgitVersion = "6.4.0.202211300538-r"
val jgitPatchBinary by configurations.creating {
    isCanBeConsumed = false
    isTransitive = false
}
val jgitPatchSources by configurations.creating {
    isCanBeConsumed = false
    isTransitive = false
}
val jgitPatchSupport by configurations.creating {
    isCanBeConsumed = false
}
val patchedParserSource = layout.buildDirectory.file(
    "generated/jgit-android/org/eclipse/jgit/internal/storage/file/ObjectDirectoryPackParser.java"
)
val patchedFileUtilsSource = layout.buildDirectory.file(
    "generated/jgit-android/org/eclipse/jgit/util/FileUtils.java"
)
val patchedFsPosixSource = layout.buildDirectory.file(
    "generated/jgit-android/org/eclipse/jgit/util/FS_POSIX.java"
)
val patchedWindowCacheSource = layout.buildDirectory.file(
    "generated/jgit-android/org/eclipse/jgit/internal/storage/file/WindowCache.java"
)
val patchedWindowCacheStatsSource = layout.buildDirectory.file(
    "generated/jgit-android/org/eclipse/jgit/storage/file/WindowCacheStats.java"
)
val patchedStringUtilsSource = layout.buildDirectory.file(
    "generated/jgit-android/org/eclipse/jgit/util/StringUtils.java"
)

val generateAndroidJgitPatch by tasks.registering {
    inputs.files(jgitPatchSources)
    outputs.files(
        patchedParserSource,
        patchedFileUtilsSource,
        patchedFsPosixSource,
        patchedWindowCacheSource,
        patchedWindowCacheStatsSource,
        patchedStringUtilsSource
    )
    doLast {
        val sourceJar = jgitPatchSources.singleFile
        fun readSource(path: String): String = zipTree(sourceJar).matching {
            include(path)
        }.singleFile.readText()

        val parserSource = readSource(
            "org/eclipse/jgit/internal/storage/file/ObjectDirectoryPackParser.java"
        )
        val patchedParser = parserSource
            // Android devices can reject an atomic move after these files become read-only.
            .replace("\t\t\ttmpPack.setReadOnly();\n", "")
            .replace("\t\t\ttmpIdx.setReadOnly();\n", "")
            .replace(
                "FileUtils.rename(tmpPack, finalPack,\n\t\t\t\t\tStandardCopyOption.ATOMIC_MOVE);",
                "renameForAndroid(tmpPack, finalPack);"
            )
            .replace(
                "FileUtils.rename(tmpIdx, finalIdx, StandardCopyOption.ATOMIC_MOVE);",
                "renameForAndroid(tmpIdx, finalIdx);"
            )
            .replace(
                "\tprivate PackLock renameAndOpenPack(String lockMessage)",
                "\tprivate static void renameForAndroid(File source, File destination)\n" +
                    "\t\t\tthrows IOException {\n" +
                    "\t\tif (source.renameTo(destination))\n" +
                    "\t\t\treturn;\n" +
                    "\t\tsource.setWritable(true, true);\n" +
                    "\t\tif (source.renameTo(destination))\n" +
                    "\t\t\treturn;\n" +
                    "\t\tthrow new IOException(\"Android could not persist the received Git pack\");\n" +
                    "\t}\n\n" +
                    "\tprivate PackLock renameAndOpenPack(String lockMessage)"
            )
        check(
            patchedParser != parserSource &&
                "tmpPack.setReadOnly()" !in patchedParser &&
                "renameForAndroid(tmpPack, finalPack)" in patchedParser
        ) {
            "The expected JGit pack parser source was not patched"
        }

        val fileUtilsSource = readSource("org/eclipse/jgit/util/FileUtils.java")
        val patchedFileUtils = fileUtilsSource
            // HarmonyOS' Android runtime can deny NIO atomic moves in the app sandbox.
            // Prefer java.io.File rename for new lock/ref/config targets, then fall back.
            .replace(
                "\t\twhile (--attempts >= 0) {\n\t\t\ttry {\n\t\t\t\tFiles.move(toPath(src), toPath(dst), options);",
                "\t\twhile (--attempts >= 0) {\n" +
                    "\t\t\tif (!dst.exists() && src.renameTo(dst))\n" +
                    "\t\t\t\treturn;\n" +
                    "\t\t\ttry {\n" +
                    "\t\t\t\tFiles.move(toPath(src), toPath(dst), options);"
            )
            .replace(
                "\t\t\t\t\t// On *nix there is no try, you do or do not\n\t\t\t\t\tFiles.move(toPath(src), toPath(dst), options);",
                "\t\t\t\t\tif (src.renameTo(dst))\n" +
                    "\t\t\t\t\t\treturn;\n" +
                    "\t\t\t\t\t// Keep the upstream NIO fallback for other filesystems.\n" +
                    "\t\t\t\t\tFiles.move(toPath(src), toPath(dst), options);"
            )
        check(
            patchedFileUtils != fileUtilsSource &&
                "!dst.exists() && src.renameTo(dst)" in patchedFileUtils
        ) {
            "The expected JGit file utility source was not patched"
        }

        val fsPosixSource = readSource("org/eclipse/jgit/util/FS_POSIX.java")
        val atomicLockStart = fsPosixSource.indexOf(
            "\t@Override\n\tpublic LockToken createNewFileAtomic(File file) throws IOException {"
        )
        val atomicLockEnd = fsPosixSource.indexOf(
            "\n\tprivate static LockToken token",
            startIndex = atomicLockStart
        )
        check(atomicLockStart >= 0 && atomicLockEnd > atomicLockStart) {
            "The expected JGit POSIX lock method was not found"
        }
        val patchedFsPosix = fsPosixSource.replaceRange(
            atomicLockStart,
            atomicLockEnd,
            "\t@Override\n" +
                "\tpublic LockToken createNewFileAtomic(File file) throws IOException {\n" +
                "\t\t// Android app-private storage is local; avoid POSIX/NFS hard links.\n" +
                "\t\treturn super.createNewFileAtomic(file);\n" +
                "\t}\n"
        )

        val windowCacheSource = readSource(
            "org/eclipse/jgit/internal/storage/file/WindowCache.java"
        )
        val patchedWindowCache = windowCacheSource
            // Android has no desktop JMX runtime. Cache statistics remain available
            // through JGit's ordinary API, but MBean publication must stay disabled.
            .replace("import org.eclipse.jgit.util.Monitoring;\n", "")
            .replace(
                "\t\t\tMonitoring.registerMBean(mbean, \"block_cache\"); //\$NON-NLS-1\$",
                "\t\t\t// JMX is unavailable on Android; keep local statistics only."
            )
        check(
            patchedWindowCache != windowCacheSource &&
                "Monitoring.registerMBean" !in patchedWindowCache
        ) {
            "The expected JGit WindowCache JMX hook was not patched"
        }

        val windowCacheStatsSource = readSource(
            "org/eclipse/jgit/storage/file/WindowCacheStats.java"
        )
        val patchedWindowCacheStats = windowCacheStatsSource
            .replace("import javax.management.MXBean;\n\n", "")
            .replace("@MXBean\n", "")
        check(
            patchedWindowCacheStats != windowCacheStatsSource &&
                "javax.management" !in patchedWindowCacheStats
        ) {
            "The expected JGit WindowCacheStats JMX annotation was not patched"
        }

        val stringUtilsSource = readSource("org/eclipse/jgit/util/StringUtils.java")
        val patchedStringUtils = stringUtilsSource.replace(
            "String n = value.strip();",
            // String.strip() is API 33 on Android; Git config numbers use ASCII whitespace.
            "String n = value.trim();"
        )
        check(patchedStringUtils != stringUtilsSource && "value.strip()" !in patchedStringUtils) {
            "The expected JGit Java 11 String API was not patched"
        }

        val parserOutput = patchedParserSource.get().asFile
        parserOutput.parentFile.mkdirs()
        parserOutput.writeText(patchedParser)
        val fileUtilsOutput = patchedFileUtilsSource.get().asFile
        fileUtilsOutput.parentFile.mkdirs()
        fileUtilsOutput.writeText(patchedFileUtils)
        val fsPosixOutput = patchedFsPosixSource.get().asFile
        fsPosixOutput.parentFile.mkdirs()
        fsPosixOutput.writeText(patchedFsPosix)
        val windowCacheOutput = patchedWindowCacheSource.get().asFile
        windowCacheOutput.parentFile.mkdirs()
        windowCacheOutput.writeText(patchedWindowCache)
        val windowCacheStatsOutput = patchedWindowCacheStatsSource.get().asFile
        windowCacheStatsOutput.parentFile.mkdirs()
        windowCacheStatsOutput.writeText(patchedWindowCacheStats)
        val stringUtilsOutput = patchedStringUtilsSource.get().asFile
        stringUtilsOutput.parentFile.mkdirs()
        stringUtilsOutput.writeText(patchedStringUtils)
    }
}

val compileAndroidJgitPatch by tasks.registering(JavaCompile::class) {
    dependsOn(generateAndroidJgitPatch)
    source(
        patchedParserSource,
        patchedFileUtilsSource,
        patchedFsPosixSource,
        patchedWindowCacheSource,
        patchedWindowCacheStatsSource,
        patchedStringUtilsSource
    )
    classpath = files(jgitPatchBinary, jgitPatchSupport)
    destinationDirectory.set(layout.buildDirectory.dir("classes/jgit-android"))
    sourceCompatibility = JavaVersion.VERSION_11.toString()
    targetCompatibility = JavaVersion.VERSION_11.toString()
    options.encoding = "UTF-8"
}

val patchedJgitJar by tasks.registering(Jar::class) {
    dependsOn(compileAndroidJgitPatch)
    archiveFileName.set("org.eclipse.jgit-$jgitVersion-android.jar")
    duplicatesStrategy = DuplicatesStrategy.EXCLUDE
    from({ zipTree(jgitPatchBinary.singleFile) }) {
        exclude("org/eclipse/jgit/internal/storage/file/ObjectDirectoryPackParser.class")
        exclude("org/eclipse/jgit/util/FileUtils.class")
        exclude("org/eclipse/jgit/util/FS_POSIX.class")
        exclude("org/eclipse/jgit/internal/storage/file/WindowCache*.class")
        exclude("org/eclipse/jgit/storage/file/WindowCacheStats.class")
        exclude("org/eclipse/jgit/util/Monitoring.class")
        exclude("org/eclipse/jgit/util/StringUtils.class")
        exclude("META-INF/*.SF", "META-INF/*.RSA", "META-INF/*.DSA")
    }
    from(compileAndroidJgitPatch.map { it.destinationDirectory })
}

android {
    namespace = "com.gitscope.mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }
    defaultConfig {
        applicationId = "com.gitscope.mobile"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
    packaging {
        resources.excludes += setOf(
            "META-INF/DEPENDENCIES",
            "META-INF/LICENSE*",
            "META-INF/NOTICE*",
            "META-INF/versions/9/OSGI-INF/MANIFEST.MF"
        )
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter { source = "../.." }

dependencies {
    jgitPatchBinary("org.eclipse.jgit:org.eclipse.jgit:$jgitVersion")
    jgitPatchSources("org.eclipse.jgit:org.eclipse.jgit:$jgitVersion:sources@jar")
    jgitPatchSupport("org.slf4j:slf4j-api:1.7.36")

    // JGit 6.4 provides protocol-level shallow cloning. Desktop-only JMX and
    // HarmonyOS-incompatible file operations are replaced in the patched jar.
    implementation(files(patchedJgitJar))
    implementation("com.googlecode.javaewah:JavaEWAH:1.1.13")
    implementation("org.slf4j:slf4j-nop:1.7.36")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}
