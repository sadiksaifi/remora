# Tool versions are pinned in mise.toml.

derived_data := "build/DerivedData"

# List the recipes.
default:
    @just --list

# Build the RDP and VNC engines into Vendor/build. Pass --clean to rebuild every stage.
engine *args:
    ./Vendor/build-engine.sh {{ args }}

# Regenerate Remora.xcodeproj from project.yml.
generate:
    xcodegen generate

# Build the Debug app.
build:
    xcodebuild -project Remora.xcodeproj -scheme Remora -configuration Debug -derivedDataPath {{ derived_data }} -quiet build

# Build the Debug app and launch a new instance of it.
run: build
    open -n {{ derived_data }}/Build/Products/Debug/Remora.app

# Run the RemoraKit tests. Extra arguments go to swift test, such as --filter.
test *args:
    swift test --package-path Packages/RemoraKit {{ args }}
