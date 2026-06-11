import java.io.File as JFile
import java.util.zip.ZipFile

plugins {
    kotlin("multiplatform")
    kotlin("plugin.serialization")
    id("app.cash.sqldelight") version "2.1.0"
}

// Engine source lives in the nyora-shared submodule — one source of truth across
// the mac/linux/windows desktop apps. This module compiles it via srcDirs.
val sharedSrc = "${rootProject.projectDir}/nyora-shared/src"

sqldelight {
    databases {
        create("NyoraDatabase") {
            packageName.set("com.nyora.hasan72341.shared.db")
            srcDirs.from(file("$sharedSrc/commonMain/sqldelight"))
        }
    }
}

kotlin {
    jvmToolchain(17)

    jvm()

    // macOS native XCFramework targets are only valid on a macOS host.
    // On Linux/Windows we skip them so the JVM-only build path works unchanged.
    val isMacOS = System.getProperty("os.name").lowercase().contains("mac")
    if (isMacOS) {
        val xcframeworkName = "NyoraShared"
        listOf(
            macosX64(),
            macosArm64(),
        ).forEach { target ->
            target.binaries.framework {
                baseName = xcframeworkName
                isStatic = true
            }
        }
    }

    sourceSets {
        val commonMain by getting {
            kotlin.srcDirs("$sharedSrc/commonMain/kotlin")
            resources.srcDirs("$sharedSrc/commonMain/resources")
            dependencies {
                implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")
                implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
                implementation("org.jetbrains.kotlinx:kotlinx-datetime:0.6.1")
                implementation("app.cash.sqldelight:runtime:2.1.0")
                implementation("app.cash.sqldelight:coroutines-extensions:2.1.0")
            }
        }
        val jvmMain by getting {
            kotlin.srcDirs("$sharedSrc/jvmMain/kotlin")
            resources.srcDirs("$sharedSrc/jvmMain/resources")
            dependencies {
                implementation("org.jetbrains.kotlinx:kotlinx-coroutines-swing:1.10.2")
                implementation("org.graalvm.js:js:24.1.2")
                implementation("org.graalvm.sdk:graal-sdk:24.1.2")
                implementation("app.cash.sqldelight:sqlite-driver:2.1.0")
                // OkHttp 4 — required by nyora parsers and our LoaderContext impl.
                implementation("com.squareup.okhttp3:okhttp:4.12.0")
                implementation("com.squareup.okhttp3:okhttp-dnsoverhttps:4.12.0")
                implementation("org.jsoup:jsoup:1.17.2")
            }
        }
        if (isMacOS) {
            // The default hierarchy template (Kotlin 2.x) auto-creates macosMain as
            // an intermediate set between commonMain and macosArm64Main / macosX64Main.
            // SQLDelight's native-driver gets attached to each leaf target so we
            // don't need to look up the intermediate set name.
            val nativeDriver = "app.cash.sqldelight:native-driver:2.1.0"
            getByName("macosArm64Main").dependencies { implementation(nativeDriver) }
            getByName("macosX64Main").dependencies { implementation(nativeDriver) }
        }
    }
}

// `gradle :shared:run` launches the JVM helper sidecar that the SwiftUI app talks to.
tasks.register<JavaExec>("run") {
    group = "application"
    description = "Run the Nyora JVM helper sidecar (HelperMain)."
    val jvmMain = kotlin.targets.getByName("jvm").compilations.getByName("main")
    dependsOn(jvmMain.compileTaskProvider)
    classpath = files(jvmMain.output.allOutputs, jvmMain.runtimeDependencyFiles)
    mainClass.set("com.nyora.hasan72341.shared.HelperMain")
    standardInput = System.`in`
    project.findProperty("nyoraHelperPortFile")?.toString()?.let { portFile ->
        systemProperty("nyora.helper.port-file", portFile)
    }
}

// One-shot parser audit: probes every Nyora parser source and reports which
// ones return data, fail with network errors, need WebView, etc.
//
//   gradle :shared:auditParsers
//   gradle :shared:auditParsers -PauditLimit=30
//
tasks.register<JavaExec>("auditParsers") {
    group = "verification"
    description = "Probe every Nyora parser source for whether it currently works."
    val jvmMain = kotlin.targets.getByName("jvm").compilations.getByName("main")
    dependsOn(jvmMain.compileTaskProvider)
    classpath = files(jvmMain.output.allOutputs, jvmMain.runtimeDependencyFiles)
    mainClass.set("com.nyora.hasan72341.shared.parser.ParserAuditMain")
    project.findProperty("auditLimit")?.toString()?.let { args("--limit=$it") }
    args("--out=${layout.buildDirectory.file("parser-audit.tsv").get().asFile.absolutePath}")
}

// `gradle :shared:helperJar` produces build/libs/nyora-helper.jar — a single-file
// runnable JAR containing HelperMain plus GraalVM JS and all runtime deps.
// The SwiftUI app launches it via `java -jar`.
//
// META-INF/services/ files need merging (not exclusion) so service-loader
// discovery still works after shading. Truffle's polyglot relies on this for
// GraalJS language registration. We pre-merge them into build/merged-services
// and exclude them from the dep zip-trees.

val mergedServicesDir = layout.buildDirectory.dir("merged-services").map { it.asFile }

tasks.register("mergeServiceFiles") {
    group = "build"
    description = "Concatenate META-INF/services entries from all helper runtime deps."
    val jvmMain = kotlin.targets.getByName("jvm").compilations.getByName("main")
    val runtimeFiles = jvmMain.runtimeDependencyFiles
    inputs.files(runtimeFiles)
    outputs.dir(mergedServicesDir)
    doLast {
        val outDir = mergedServicesDir.get()
        outDir.deleteRecursively()
        val servicesOut = JFile(outDir, "META-INF/services").apply { mkdirs() }
        val accum = mutableMapOf<String, StringBuilder>()
        runtimeFiles!!.filter { it.isFile && it.name.endsWith(".jar") }.forEach { jar ->
            ZipFile(jar).use { zf ->
                val entries = zf.entries()
                while (entries.hasMoreElements()) {
                    val entry = entries.nextElement()
                    if (!entry.isDirectory &&
                        entry.name.startsWith("META-INF/services/") &&
                        entry.name.length > "META-INF/services/".length
                    ) {
                        val key = entry.name.removePrefix("META-INF/services/")
                        val text = zf.getInputStream(entry).bufferedReader().readText()
                        accum.getOrPut(key) { StringBuilder() }.append(text).append('\n')
                    }
                }
            }
        }
        accum.forEach { (name, content) ->
            JFile(servicesOut, name).writeText(content.toString())
        }
        println("Merged ${accum.size} META-INF/services files into $outDir")
    }
}

tasks.register<Jar>("helperJar") {
    group = "build"
    description = "Build a fat JAR for the Nyora JVM helper sidecar."
    archiveBaseName.set("nyora-helper")
    archiveVersion.set("")
    archiveClassifier.set("")
    duplicatesStrategy = DuplicatesStrategy.EXCLUDE

    manifest {
        attributes(
            "Main-Class" to "com.nyora.hasan72341.shared.HelperMain",
            "Multi-Release" to "true",
        )
    }

    val jvmMain = kotlin.targets.getByName("jvm").compilations.getByName("main")
    dependsOn(jvmMain.compileTaskProvider)
    dependsOn("jvmProcessResources")
    dependsOn("mergeServiceFiles")

    from(jvmMain.output.allOutputs)
    from(mergedServicesDir)
    from(provider {
        jvmMain.runtimeDependencyFiles!!.filter { it.isDirectory || it.name.endsWith(".jar") }
            .map { file -> if (file.isDirectory) file else zipTree(file) }
    }) {
        exclude(
            "META-INF/*.SF",
            "META-INF/*.DSA",
            "META-INF/*.RSA",
            "META-INF/*.EC",
            "META-INF/MANIFEST.MF",
            "META-INF/LICENSE",
            "META-INF/LICENSE.txt",
            "META-INF/NOTICE",
            "META-INF/NOTICE.txt",
            "META-INF/services/**",   // ← merged separately, see mergeServiceFiles
            "module-info.class",
        )
    }
}
