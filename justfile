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
build-pkg PACKAGE ENV='mainnet':
    sui move build --path "{{PACKAGE}}" -e "{{ENV}}"

# Build both packages
build:
    @just build-pkg talus
    @just build-pkg faucet
    @just build-pkg deposit_pool
    @just build-pkg loyalty

# Helper: Test a specific package
test-pkg PACKAGE ENV='mainnet':
    sui move test --path "{{PACKAGE}}" -e "{{ENV}}"

# Test both packages
test:
    @just test-pkg talus
    @just test-pkg faucet    
    @just test-pkg deposit_pool
    @just test-pkg loyalty


# Helper: Test with coverage for a specific package
test-cov-pkg PACKAGE ENV='mainnet':
    sui move test --path "{{PACKAGE}}" -e "{{ENV}}" --coverage

# Run coverage tests on both packages
test-cov:
    @just test-cov-pkg talus
    @just test-cov-pkg faucet
    @just test-cov-pkg loyalty
    @just test-cov-pkg deposit_pool

# Build and test with report to console
build-test-report PACKAGE:
    @just build-pkg {{PACKAGE}}
    @just test-cov-pkg {{PACKAGE}}
    cd ./{{PACKAGE}} && sui move coverage summary

test-report:
    @just build-test-report talus
    @just build-test-report faucet
    @just build-test-report loyalty
    @just build-test-report deposit_pool

# Build and test in one command
build-test: build test

# Check the token address used by a consumer package
test-dependency ENV='mainnet':
    python3 Tests/dependency/verify.py dependency "{{ENV}}"

# Reproduce the published token module with Sui 1.59.1
verify-token-bytecode:
    python3 Tests/dependency/verify.py bytecode

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
