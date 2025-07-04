#!/usr/bin/perl

use strict;
use warnings;
use feature 'say';

use JSON;
use File::Slurp;
use File::Basename;
use File::Path qw(make_path);
use File::Spec;
use Fcntl qw(:flock);
use IPC::Run qw(run);
use Time::Piece;
use Term::ProgressBar;

# Define the lock file path
my $lock_file = "/tmp/DatabaseBackupScript.lock";

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

# Load configuration
my $config_file = 'config.json';
unless (-e $config_file) {
    die "Config file $config_file not found!\n";
}

my $json_text = read_file($config_file);
my $config = decode_json($json_text);

# Get current timestamp for logging
my $timestamp = localtime->strftime('%Y-%m-%d %H:%M:%S');
say "[$timestamp] Starting database backup process";

# Initialize progress tracking
my $total_tasks = calculate_total_tasks($config);
my $current_task = 0;
my $progress = Term::ProgressBar->new({
    name => 'Backup Progress',
    count => $total_tasks,
    ETA => 'linear',
    remove => 1,
    max_update_rate => 1
});

# Process remote backups if enabled
if ($config->{remotely} && $config->{remotely}{enabled}) {
    $current_task = process_remote_database_backups($config->{remotely}{servers}, $progress, $current_task);
}

$timestamp = localtime->strftime('%Y-%m-%d %H:%M:%S');
say "[$timestamp] Database backup process completed";

exit 0;

# Subroutines
sub calculate_total_tasks {
    my ($config) = @_;
    my $count = 0;
    
    if ($config->{remotely} && $config->{remotely}{enabled}) {
        foreach my $server (@{$config->{remotely}{servers}}) {
            foreach my $db (@{$server->{databases}}) {
                $count += scalar @{$db->{database_names}} * scalar @{$db->{paths}};
            }
        }
    }
    
    return $count || 1; # Ensure at least 1 to avoid division by zero
}

sub process_remote_database_backups {
    my ($servers, $progress, $current_task) = @_;
    
    foreach my $server (@$servers) {
        my $ssh = $server->{ssh};
        my $ssh_user = $ssh->{username};
        my $ssh_host = $ssh->{host};
        my $ssh_port = $ssh->{port} || 22;
        
        foreach my $db (@{$server->{databases}}) {
            my $engine = $db->{engine};
            my $db_host = $db->{host};
            my $db_user = $db->{user};
            my $db_pass = $db->{password};
            
            foreach my $db_name (@{$db->{database_names}}) {
                foreach my $local_backup_path (@{$db->{paths}}) {
                    $progress->message("Preparing to backup: $ssh_host:$db_name");
                    $progress->update($current_task++);
                    
                    # Create local dated folder structure: local_path/db_name/YYYY-MM-DD__HH_MM_SS
                    my $datetime_folder = localtime->strftime('%Y-%m-%d__%H_%M_%S');
                    my $final_local_path = File::Spec->catdir($local_backup_path, $db_name, $datetime_folder);
                    
                    unless (-d $final_local_path) {
                        make_path($final_local_path) or die "Failed to create local directory '$final_local_path': $!\n";
                    }
                    
                    my $backup_file = File::Spec->catfile($final_local_path, "$db_name.sql");
                    
                    $progress->message("Backing up $ssh_host:$db_name to local $final_local_path");
                    
                    my ($success, $error);
                    if ($engine eq 'mysql') {
                        ($success, $error) = remote_mysql_backup(
                            $ssh_user, $ssh_host, $ssh_port,
                            $db_host, $db_user, $db_pass, 
                            $db_name, $backup_file, 
                            $progress, $current_task
                        );
                    } else {
                        $error = "Unsupported database engine: $engine";
                        $success = 0;
                    }
                    
                    if ($success) {
                        # Compress the backup file
                        $progress->message("Compressing backup...");
                        compress_backup($backup_file, $progress);
                        $progress->message("Backup completed: $ssh_host:$db_name -> $final_local_path/$db_name.sql.gz");
                    } else {
                        $progress->message("Error: Backup failed for $ssh_host:$db_name: $error");
                    }
                    
                    $current_task++;
                }
            }
        }
    }
    
    return $current_task;
}

sub remote_mysql_backup {
    my ($ssh_user, $ssh_host, $ssh_port,
        $db_host, $db_user, $db_pass,
        $db_name, $backup_file,
        $progress, $task_num) = @_;
    
    # Build the mysqldump command to run on remote server
    my $dump_cmd = "mysqldump --host=$db_host --user=$db_user --password=$db_pass " .
                   "--single-transaction --quick --skip-lock-tables $db_name";
    
    # Command to execute remotely via SSH and save locally
    my @cmd = (
        'ssh', '-p', $ssh_port, "$ssh_user\@$ssh_host", $dump_cmd
    );
    
    open(my $out_fh, '>', $backup_file) or return (0, "Cannot open output file: $!");
    
    my $stderr;
    eval {
        run \@cmd, \undef, $out_fh, \$stderr;
    };
    
    close($out_fh);
    
    if ($@) {
        return (0, $@);
    } elsif ($stderr) {
        return (0, $stderr);
    } else {
        return (1, '');
    }
}

sub compress_backup {
    my ($backup_file, $progress) = @_;
    
    return unless -f $backup_file;
    
    my @gzip_cmd = ('gzip', $backup_file);
    my ($success, $error) = run_command_with_progress(\@gzip_cmd, $progress, 0);
    
    unless ($success) {
        $progress->message("Warning: Compression failed: $error");
    }
    
    return $success;
}

sub run_command_with_progress {
    my ($cmd, $progress, $task_num) = @_;
    
    my ($stdout, $stderr);
    my $output = '';
    
    my $progress_cb = sub {
        my $input = shift;
        $output .= $input;
        $progress->update($task_num, $input);
    };
    
    eval {
        run $cmd, \undef, $progress_cb, \$stderr;
    };
    
    if ($@) {
        return (0, $@);
    } elsif ($stderr) {
        return (0, $stderr);
    } else {
        return (1, $output);
    }
}
