# Protozoa Dev

CLI tool for the Protozoa Protocol Buffers library. This package provides code generation from `.proto` files to Gleam code.

[![Package Version](https://img.shields.io/hexpm/v/protozoa_dev)](https://hex.pm/packages/protozoa_dev)

## Installation

Add `protozoa_dev` as a dev dependency:

```bash
gleam add protozoa_dev --dev
```

## Usage

### Basic Code Generation

```bash
# Generate code from a proto file
gleam run -m protozoa/dev -- input.proto output_dir

# Generate with import paths
gleam run -m protozoa/dev -- -Iproto -Ivendor user.proto src/generated

# Show help
gleam run -m protozoa/dev -- --help
```

### Auto-detection Mode

The CLI can automatically detect your project structure:

```bash
# Auto-detect and generate
gleam run -m protozoa/dev

# Check if files need regeneration
gleam run -m protozoa/dev check
```

## Project Structure

The auto-detection mode looks for proto files in:
- `src/[project-name]/proto/`

And generates Gleam code alongside the proto files.

## Features

- **Complete proto3 support** - All message types, enums, oneofs, maps, repeated fields
- **Import resolution** - Handles `import` statements with configurable search paths  
- **Well-known types** - Google's standard protobuf types (Timestamp, Duration, etc.)
- **Service definitions** - gRPC service stubs with streaming support
- **Field options** - Support for deprecated, json_name, packed options
- **Auto-detection** - Discovers project structure automatically
- **Safety headers** - Generated files include regeneration instructions

## Generated Code

From this proto file:

```proto
syntax = "proto3";

message User {
  string name = 1;
  int32 age = 2;
  bool active = 3;
}
```

The CLI generates:

```gleam
import protozoa/decode
import protozoa/encode

pub type User {
  User(name: String, age: Int, active: Bool)
}

pub fn encode_user(user: User) -> BitArray {
  encode.message([
    encode.string_field(1, user.name),
    encode.int32_field(2, user.age),
    encode.bool_field(3, user.active),
  ])
}

pub fn user_decoder() -> decode.Decoder(User) {
  use name <- decode.then(decode.string_with_default(1, ""))
  use age <- decode.then(decode.int32_with_default(2, 0))
  use active <- decode.then(decode.bool_with_default(3, False))
  decode.success(User(name: name, age: age, active: active))
}

pub fn decode_user(data: BitArray) -> Result(User, List(decode.DecodeError)) {
  decode.run(data, user_decoder())
}
```

## CLI Options

```
Protozoa Dev - Protocol Buffer Compiler CLI for Gleam

Recommended Usage:
  gleam run -m protozoa/dev                 # Auto-detect and generate
  gleam run -m protozoa/dev check         # Check for changes

Advanced Usage:
  gleam run -m protozoa/dev input.proto [dir]  # Manual mode
  gleam run -m protozoa/dev -Ipath input.proto # With import paths

Options:
  -I<path>                                 # Add import search path
  --help                                   # Show help
```

## Dependencies

This package depends on:
- `protozoa` - Core Protocol Buffers library
- Standard Gleam libraries for file I/O and argument parsing

## License

This project is licensed under the MIT License.