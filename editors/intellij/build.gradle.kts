plugins {
  kotlin("jvm")
  id("org.jetbrains.intellij.platform")
}

group = "com.jtycedgetech"
version = "1.1.0"

intellijPlatform {
  // This plugin contributes no Settings page, so there is nothing to index —
  // and the indexer launches a headless IDE, which a local install does not
  // support. Skipping it keeps `buildPlugin` a plain packaging step.
  buildSearchableOptions = false

  pluginConfiguration {
    // 253 is the 2025.3 platform branch, which Android Studio 2025.3 is built
    // on. Left open-ended upwards: this uses only core platform API.
    ideaVersion {
      sinceBuild = "241"
      untilBuild = provider { null }
    }
  }

  // `gradle publishPlugin` is the only way to ship an update: the Marketplace
  // web form takes new plugins only, and rejects an id it already knows.
  //
  // The token is a credential, so it is read from the environment or from
  // ~/.gradle/gradle.properties — never from this repository. Make one at
  // https://plugins.jetbrains.com/author/me/tokens
  publishing {
    token = providers.environmentVariable("JETBRAINS_MARKETPLACE_TOKEN")
      .orElse(providers.gradleProperty("intellijPlatformPublishingToken"))
  }
}

repositories {
  mavenCentral()
  intellijPlatform { defaultRepositories() }
}

dependencies {
  intellijPlatform {
    // Built against the Android Studio installed on this machine, so no
    // multi-gigabyte SDK download is needed to work on it.
    local(providers.gradleProperty("amscan.ideHome"))
    instrumentationTools()
  }
  implementation(project(":report"))
}

kotlin {
  jvmToolchain(17)
}

// The IntelliJ platform plugin rewires `test` to run inside a sandboxed IDE.
// There is nothing here to test that way: the logic lives in `:report`, which
// has no IDE dependency and runs its own tests in a plain JVM.
tasks.test { enabled = false }
