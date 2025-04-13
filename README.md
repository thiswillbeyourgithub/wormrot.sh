# Wormhole Rotator

A script that generates synchronized, time-based magic-wormhole codes between computers without requiring prior communication.

## Overview

Wormhole Rotator is a wrapper around [magic-wormhole](https://magic-wormhole.readthedocs.io/) that automatically generates synchronized codes based on time. This eliminates the need to manually share codes between sender and receiver, making file transfers more seamless.

This project is in the same vein as my [knockd_rotator](https://github.com/thiswillbeyourgithub/knockd_rotator) and uses my [HumanReadableSeed](https://github.com/thiswillbeyourgithub/HumanReadableSeed) to generate deterministic, human-readable codes.

## Why Use This?

Wormhole Rotator solves a common problem: when transferring files with magic-wormhole, you normally need to share a code from the sender to the receiver. This can be somewhat annoying.

With Wormhole Rotator:
- Both parties simply run the same command on their respective machines
- The code is automatically generated based on the current time and a shared salt and modulo
- No communication of codes during the transfer is required
- The code changes predictably over time, making it virtually impossible for attackers to guess

It's especially useful for regularly transferring files between your own devices or with trusted parties who have the same salt and modulo configured.

## Installation

1. Ensure you have `uv` installed on your system
2. Set up the `WORMHOLE_ROTATOR_SALT` environment variable (must be non-empty)
2. Set up the `WORMHOLE_ROTATOR_MODULO` environment variable (changing it increases security, setting it too low can make it hard to synchronize)
3. Make the script executable

```bash
chmod +x wormhole_rotator.sh
```

## Usage

First, set up the salt environment variable:

```bash
export WORMHOLE_ROTATOR_SALT="your-secret-salt-here"
```

### Sending files

```bash
./wormhole_rotator.sh send /path/to/file
```

### Receiving files

```bash
./wormhole_rotator.sh receive
```

### Version information

```bash
./wormhole_rotator.sh -v
# or
./wormhole_rotator.sh --version
```

## Configuration

The script can be customized using these environment variables:

- `WORMHOLE_ROTATOR_MODULO`: Time period in seconds (default: 30, minimum: 20). Lowering it makes the code change often but if you take too much time to launch the receive commands they will never find each other.
- `WORMHOLE_ROTATOR_SALT`: Required secret salt for code generation
- `WORMHOLE_ROTATOR_BIN`: Command to run wormhole (default: "uvx --from magic-wormhole@latest wormhole")
- `WORMHOLE_ROTATOR_DEFAULT_SEND_ARGS`: Default arguments for send command (default: "--no-qr")
- `WORMHOLE_ROTATOR_DEFAULT_RECEIVE_ARGS`: Default arguments for receive command (default: "")

## How It Works

The script generates synchronized codes through a series of steps:

1. **Time Synchronization**: 
   - Gets the current UNIX timestamp (using UTC time)
   - Applies modulo to create time windows (default 30s)
   - Adjusts modulo slightly for timestamps with small remainders

2. **Period Key Generation**:
   - Creates a unique key for the current time period using the formula:
     `PERIOD_KEY = ((current_timestamp / modulo) * modulo) + salt`
   - Calculates SHA-256 hash of the period key for enhanced security

3. **Mnemonic Generation**:
   - Uses HumanReadableSeed to generate memorable words from the hashed period key
   - Formats the words with hyphens

4. **Channel ID Generation**:
   - Calculates a hash of the mnemonic words
   - Extracts digits from the hash
   - Computes a prefix number (modulo 999 to cap it  to 3 digits) (what magic-wormhole calls [nameplates or channel id](https://magic-wormhole.readthedocs.io/en/latest/api.html))
   - Creates the final code format: `prefix-mnemonic`

5. **Command Execution**:
   - Uses the generated code with the magic-wormhole send or receive command

The beauty of this approach is that both sides independently generate the same code without direct communication.

## Development

This tool was created with the help of [aider.chat](https://github.com/Aider-AI/aider/issues).

## License

See the LICENSE file for details.
