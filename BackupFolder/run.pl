use strict;
use warnings;
use JSON;
use File::Slurp;
use feature 'say';
use File::Basename;
use File::Temp qw(tempfile);
use Fcntl qw(:flock);

# Define the lock file path
my $lock_file = "/tmp/BackupFolderScript.lock";

# Try to create a lock file
open(my $lock_fh, '>', $lock_file) or die "Could not open lock file: $!";
# Try to acquire an exclusive lock
unless (flock($lock_fh, LOCK_EX | LOCK_NB)) {
    die "Another instance of the script is already running.\n";
}

# Ensure the lock file is removed on exit
END {
    close($lock_fh);
    unlink $lock_file if -e $lock_file;
}

# Your script logic goes here
say "Script is running...";

my $config = 'config.json';
my $json_text = read_file($config);
my $data_config = decode_json($json_text);

sleep(10);

say "Script finished successfully.";
