rootProject.name = "amscan-report-intellij"

pluginManagement {
  plugins {
    kotlin("jvm") version "2.2.0"
    id("org.jetbrains.intellij.platform") version "2.1.0"
  }
  repositories {
    gradlePluginPortal()
    maven("https://download.jetbrains.com/teamcity-repository")
  }
}

include("report")
