plugins {
    kotlin("jvm") version "2.2.10"
    kotlin("plugin.serialization") version "2.2.10"
    id("com.gradleup.shadow") version "8.3.6"
    application
}

repositories {
    mavenCentral()
    // androidx.collection (a JVM-compatible multiplatform lib used by
    // kotatsu-parsers) lives on Google's Maven repository.
    google()
    // kotatsu-parsers is published via JitPack only. The first
    // resolution of a freshly pinned version triggers a remote build
    // on jitpack.io and can take several minutes (or flake once) —
    // just retry.
    maven { url = uri("https://jitpack.io") }
}

val ktorVersion = "3.1.2"

// Pinned kotatsu-parsers commit. Bumping this = picking up community
// site fixes; see README for the procedure.
// NOTE: upstream KotatsuApp/kotatsu-parsers was ARCHIVED in Nov 2025;
// Kotatsu-Redo/kotatsu-parsers-redo is the actively-maintained
// community continuation (drop-in: same packages and API).
// (7-char hash: JitPack's build of the 10-char form of this same
// commit died on their infra; the short form built fine)
val parsersVersion = "dbd62fb"

dependencies {
    implementation("com.github.Kotatsu-Redo:kotatsu-parsers-redo:$parsersVersion")
    // Keep in sync with kotatsu-parsers' own okhttp pin
    // (gradle/libs.versions.toml in their repo) — parsers reference
    // okhttp internals, and a lower version here breaks some sources
    // at runtime with NoClassDefFoundError.
    implementation("com.squareup.okhttp3:okhttp:5.1.0")
    // Nashorn was removed from the JDK in Java 15; some parsers call
    // evaluateJs and fail with a confusing engine-not-found error
    // without this.
    implementation("org.openjdk.nashorn:nashorn-core:15.6")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")

    implementation("io.ktor:ktor-server-netty:$ktorVersion")
    implementation("io.ktor:ktor-server-content-negotiation:$ktorVersion")
    implementation("io.ktor:ktor-serialization-kotlinx-json:$ktorVersion")
    implementation("io.ktor:ktor-server-call-logging:$ktorVersion")
    implementation("io.ktor:ktor-server-status-pages:$ktorVersion")
    implementation("ch.qos.logback:logback-classic:1.5.18")
}

kotlin {
    jvmToolchain(21)
}

application {
    mainClass.set("sidecar.MainKt")
}

tasks.shadowJar {
    archiveBaseName.set("kotatsu-sidecar")
    archiveClassifier.set("")
    archiveVersion.set("")
    manifest {
        attributes["Implementation-Version"] = parsersVersion
    }
    mergeServiceFiles()
}

// Expose the pin to the app at runtime (for /health).
tasks.processResources {
    inputs.property("parsersVersion", parsersVersion)
    filesMatching("sidecar.properties") {
        expand("parsersVersion" to parsersVersion)
    }
}
