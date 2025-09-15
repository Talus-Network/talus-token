# Default recipe: list all available commands
default:
    @just --list

# Helper: Clean a specific package
clean-pkg PACKAGE:
    cd ./{{PACKAGE}} && rm -rf build/

# Clean both packages
clean:
    @just clean-pkg talus
    @just clean-pkg faucet
    @just clean-pkg deposit_pool
    @just clean-pkg loyalty

# Helper: Build a specific package
build-pkg PACKAGE:
    cd ./{{PACKAGE}} && sui move build --skip-fetch-latest-git-deps

# Build both packages
build:
    @just build-pkg talus
    @just build-pkg faucet
    @just build-pkg deposit_pool
    @just build-pkg loyalty

# Helper: Test a specific package
test-pkg PACKAGE:
    cd ./{{PACKAGE}} && sui move test --skip-fetch-latest-git-deps

# Test both packages
test:
    @just test-pkg talus
    @just test-pkg faucet    
    @just test-pkg deposit_pool
    @just test-pkg loyalty


# Helper: Test with coverage for a specific package
test-cov-pkg PACKAGE:
    cd ./{{PACKAGE}} && sui move test --coverage

# Run coverage tests on both packages
test-cov:
    @just test-cov-pkg talus
    @just test-cov-pkg faucet
    @just test-cov-pkg loyalty
    @just test-cov-pkg deposit_pool

# Build and test with report to console
build-test-report PACKAGE:
    @just build
    @just test-cov
    cd ./{{PACKAGE}} && sui move coverage summary

test-report:
    @just build-test-report talus
    @just build-test-report faucet

# Build and test in one command
build-test: build test

# Helper: Publish a specific package and log created objects (type:id) to the given file
publish-log-pkg PACKAGE FILE:
    # Add a section header for clarity
    echo "# {{PACKAGE}} package" >> {{FILE}}
    echo "Type | ObjectID" >> {{FILE}}
    echo "--- | ---" >> {{FILE}}
    # Publish and extract package id + created objects, formatting as table rows
    sui client publish ./{{PACKAGE}} --json 2>/dev/null \
        | jq -r '(.objectChanges[] | select(.type=="published") | "package | " + .packageId), (.objectChanges[] | select(.type=="created") | "\(.objectType) | \(.objectId)")' >> {{FILE}}
    echo "" >> {{FILE}}

# Publish pools package first, then iao package, recording all created objects in one file
# Usage: just publish-log [FILE=published_objects.txt]
publish-log FILE='published_objects.txt':
    rm -f {{FILE}}
    touch {{FILE}}
    @just publish-log-pkg talus {{FILE}}
    @just publish-log-pkg faucet {{FILE}}