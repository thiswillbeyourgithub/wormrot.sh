# WormRot v1.1.0

A script that generates synchronized, time-based magic-wormhole codes between computers without requiring prior communication.

## Overview

WormRot (=Wormhole Rotator) is a wrapper around [magic-wormhole](https://magic-wormhole.readthedocs.io/) that automatically generates synchronized codes based on time. This eliminates the need to manually share codes between sender and receiver, making file transfers more seamless.

This tool explicitly supports sending multiple files in a single operation, handling the complexity of coordinating multiple transfers automatically.

This project is in the same vein as my [knockd_rotator](https://github.com/thiswillbeyourgithub/knockd_rotator) and uses my [HumanReadableSeed](https://github.com/thiswillbeyourgithub/HumanReadableSeed) to generate deterministic, human-readable codes.

## Why Use This?

WormRot solves a common problem: when transferring files with magic-wormhole, you normally need to share a code from the sender to the receiver. This can be somewhat annoying.

With WormRot:
- Both parties simply run the same command on their respective machines
- The code is automatically generated based on the current time and a shared salt and modulo
- No communication of codes during the transfer is required
- The code changes predictably over time, making it virtually impossible for attackers to guess
- Send multiple files in a single operation with automatic coordination between sender and receiver

It's especially useful for regularly transferring files between your own devices or with trusted parties who have the same salt and modulo configured.

## Installation

1. Ensure you have `uv` installed on your system
2. Set up the `WORMROT_SALT` environment variable (must be non-empty)
3. Set up the `WORMROT_MODULO` environment variable (changing it increases security, setting it too low can make it hard to synchronize)
4. Make the script executable

```bash
chmod +x wormrot.sh
```

## Usage

First, set up the salt environment variable:

```bash
export WORMROT_SALT="your-secret-salt-here"
```

The script automatically detects what you want to do:
- Run with file paths to send files
- Run without arguments to receive files

### Sending files

```bash
# Provide file paths to send files
./wormrot.sh /path/to/file1 /path/to/file2
```

### Receiving files

```bash
# Run without arguments to receive files
./wormrot.sh
```

### Help and version information

```bash
# Show help
./wormrot.sh -h
# or
./wormrot.sh --help

# Show version
./wormrot.sh -v
# or
./wormrot.sh --version
```

## Configuration

The script can be customized using these environment variables:

- `WORMROT_MODULO`: Time period in seconds (default: 30, minimum: 20). Lowering it makes the code change often but if you take too much time to launch the receive commands they will never find each other.
- `WORMROT_SALT`: Required secret salt for code generation
- `WORMROT_BIN`: Command to run wormhole (default: "uvx --from magic-wormhole@latest wormhole")
- `WORMROT_DEFAULT_SEND_ARGS`: Default arguments for send command (default: "--no-qr --hide-progress")
- `WORMROT_DEFAULT_RECEIVE_ARGS`: Default arguments for receive command (default: "--hide-progress")

## How It Works

The script generates synchronized codes through a series of steps:

1. **Time Synchronization**: 
   - Gets the current UNIX timestamp (using UTC time)
   - Applies modulo to create time windows (default 30s)
   - Adjusts modulo slightly for timestamps with small remainders

2. **Period Key Generation**:
   - Creates a unique key for the current time period using the formula:
     `PERIOD_KEY = ((current_timestamp / modulo) * modulo) + salt + optional_suffix`
   - The suffix is used to generate different codes for multiple files in the same transfer
   - Calculates SHA-256 hash of the period key for enhanced security

3. **Mnemonic Generation**:
   - Uses HumanReadableSeed to generate memorable words from the hashed period key
   - Formats the words with hyphens

4. **Channel ID Generation**:
   - Calculates a hash of the mnemonic words
   - Extracts digits from the hash
   - Computes a prefix number (modulo 999 to cap it to 3 digits) (what magic-wormhole calls [nameplates or channel id](https://magic-wormhole.readthedocs.io/en/latest/api.html))
   - Creates the final code format: `prefix-mnemonic`

5. **File Transfer Process**:
   - For sending: First sends the number of files, then sends each file with a unique suffix-based code
   - For receiving: First receives the file count, then receives each file using the same suffix pattern

The beauty of this approach is that both sides independently generate the same code without direct communication.

## Development

This tool was created with the help of [aider.chat](https://github.com/Aider-AI/aider/issues).

## License

See the LICENSE file for details.
