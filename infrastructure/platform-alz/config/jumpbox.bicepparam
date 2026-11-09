using './jumpbox.bicep'

// Read from the environment so the password never lands in a parameter file or on a command line.
param adminPassword = readEnvironmentVariable('JUMPBOX_ADMIN_PASSWORD')
