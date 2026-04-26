# Error Policy Review

This assembly adds a consistent input-validation policy to `New-GoldenVmInteractive.ps1`.

## Policy

- Interactive mode: invalid user input shows a clear warning and asks for the value again.
- `-Auto` mode: invalid input fails fast with a clear error message.
- Every validation message should identify:
  - the field name,
  - the current invalid value,
  - the expected format,
  - where to fix it: config file or CLI override.

## Added validation coverage

- Required non-empty values.
- Required existing paths.
- Repository root structure.
- Hyper-V switch existence.
- MAC address format.
- Static IP/CIDR format.
- Static IP prefix format.
- IP last octet range.
- Gateway IPv4 format.
- DNS server IPv4 list validation.
- Memory/CPU/controller numeric ranges.
- Memory consistency: `MinimumMemoryGb <= MemoryStartupGb <= MaximumMemoryGb`.

## Notes

PowerShell parameter binding errors, such as passing a non-boolean string to a `[bool]` parameter, may still be raised by PowerShell before the script body runs. Runtime/config values are handled by the wrapper validation layer.
