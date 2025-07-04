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

# Load configuration
my $config_file = 'config.json';
unless (-e $config_file) {
    die "Config file $config_file not found!\n";
}

my $json_text = read_file($config_file);
my $config = decode_json($json_text);

# Get current timestamp for logging
my $timestamp = localtime->strftime('%Y-%m-%d %H:%M:%S');
say "[$timestamp] Starting backup process";

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

# Process local backups if enabled
if ($config->{localy} && $config->{localy}{enabled}) {
    $current_task = process_local_backups($config->{localy}{paths}, $progress, $current_task);
}

# Process remote backups if enabled
if ($config->{remotely} && $config->{remotely}{enabled}) {
    $current_task = process_remote_backups($config->{remotely}{servers}, $progress, $current_task);
}

$timestamp = localtime->strftime('%Y-%m-%d %H:%M:%S');
say "[$timestamp] Backup process completed";

exit 0;

# Subroutines
sub calculate_total_tasks {
    my ($config) = @_;
    my $count = 0;
    
    if ($config->{localy} && $config->{localy}{enabled}) {
        $count += scalar @{$config->{localy}{paths}};
    }
    
    if ($config->{remotely} && $config->{remotely}{enabled}) {
        foreach my $server (@{$config->{remotely}{servers}}) {
            $count += scalar @{$server->{paths}};
        }
    }
    
    return $count || 1; # Ensure at least 1 to avoid division by zero
}

sub process_local_backups {
    my ($paths, $progress, $current_task) = @_;
    
    foreach my $path (@$paths) {
        my $source = $path->{source};
        my $target = $path->{target};
        
        $progress->message("Preparing to backup: $source");
        $progress->update($current_task++);
        
        unless (-d $source) {
            $progress->message("Warning: Source directory '$source' does not exist, skipping");
            next;
        }
        
        # Get source directory name and create date-time string
        my $source_name = basename($source);
        my $datetime_folder = localtime->strftime('%Y-%m-%d__%H_%M_%S');
        
        # Create target path: target/source_name/date_time
        my $final_target = File::Spec->catdir($target, $source_name, $datetime_folder);
        
        unless (-d $final_target) {
            make_path($final_target) or die "Failed to create target directory '$final_target': $!\n";
        }
        
        $progress->message("Starting local backup: $source -> $final_target");
        
        # Rsync command with progress and symlink protection
        my @rsync_cmd = (
            'rsync',
            '-avz',
            '--progress',
            '--delete',
            '--no-links',
            '--safe-links',
            '--copy-unsafe-links',
            $source.'/',
            $final_target.'/'
        );
        
        my ($success, $error) = run_command_with_progress(\@rsync_cmd, $progress, $current_task);
        if ($success) {
            $progress->message("Local backup completed: $source -> $final_target");
        } else {
            $progress->message("Error: Local backup failed: $source -> $final_target\n$error");
        }
        
        $current_task++;
    }
    
    return $current_task;
}

sub process_remote_backups {
    my ($servers, $progress, $current_task) = @_;
    
    foreach my $server (@$servers) {
        my $ssh = $server->{ssh};
        my $username = $ssh->{username};
        my $host = $ssh->{host};
        my $port = $ssh->{port} || 22;
        
        foreach my $path (@{$server->{paths}}) {
            my $source = $path->{source};
            my $target = $path->{target};
            
            $progress->message("Preparing remote backup: $host:$source");
            $progress->update($current_task++);
            
            # Get source directory name and create date-time string
            my $source_name = basename($source);
            my $datetime_folder = localtime->strftime('%Y-%m-%d__%H_%M_%S');
            
            # Create target path: target/source_name/date_time
            my $final_target = File::Spec->catdir($target, $source_name, $datetime_folder);
            
            unless (-d $final_target) {
                make_path($final_target) or die "Failed to create target directory '$final_target': $!\n";
            }
            
            $progress->message("Starting remote backup: $host:$source -> $final_target");
            
            # Rsync command with progress and symlink protection
            my @rsync_cmd = (
                'rsync',
                '-avz',
                '--progress',
                '--delete',
                '--no-links',
                '--safe-links',
                '--copy-unsafe-links',
                '-e', "ssh -p $port",
                "$username\@$host:$source/",
                "$final_target/"
            );
            
            my ($success, $error) = run_command_with_progress(\@rsync_cmd, $progress, $current_task);
            if ($success) {
                $progress->message("Remote backup completed: $host:$source -> $final_target");
            } else {
                $progress->message("Error: Remote backup failed: $host:$source -> $final_target\n$error");
            }
            
            $current_task++;
        }
    }
    
    return $current_task;
}

sub run_command_with_progress {
    my ($cmd, $progress, $task_num) = @_;
    
    my ($stdout, $stderr);
    my $output = '';
    
    # Create a sub to handle progress updates
    my $progress_cb = sub {
        my $input = shift;
        $output .= $input;
        
        # Update progress for each line of output
        if ($input =~ /(\d+)%\s+([\d.]+[KM]?B)\/s\s+([\d:]+)\s+ETA/) {
            my ($percent, $speed, $eta) = ($1, $2, $3);
            $progress->update($task_num, "Progress: $percent% at $speed/s, ETA: $eta");
        }
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
