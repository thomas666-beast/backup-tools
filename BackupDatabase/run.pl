
use strict;
use warnings;
use JSON;
use File::Slurp;
use feature 'say';

# Read the JSON file
my $config = 'config.json';
my $json_text = read_file($config);

# Decode the JSON data
my $data_config = decode_json($json_text);

sub generate_backup_localy {
    my $data = shift;

    if (1 == $data -> { localy } { enabled } ) {
        say "localy is enabled";

        for my $database (@{ $data->{localy}->{databases} }) {

            say '-- engine: ' . $database->{engine};
            say '-- host: ' . $database->{host};
            say '-- user: ' . $database->{user};
            say '-- password: ' . $database->{password};
            say '';
            say '-- datbase names to backup:';

            for my $db_name (@{ $database->{database_names} }) {
                say '---- '  . $db_name;
            }

            say '';

            say '-- paths where to backup:';

            for my $path (@{ $database->{paths} }) {
                say '---- '  . $path;
            }

        }

    } else {
        say "localy is not enbaled";
    }
}

sub generate_backup_remotely {
    my $data = shift;

    if (1 == $data -> { remotely } { enabled }) {
        say "remotely is enabled";

        for my $server (@{ $data->{remotely}->{servers} }) {
            say "ssh server";
            say '-- username: ' . $server -> {ssh} { username };
            say '-- host: ' . $server -> {ssh} { host };
            say '-- port: ' . $server -> {ssh} { port };

            say '';

            for my $database (@{ $server->{databases} }) {
                say '-- engine: ' . $database->{engine};
                say '-- host: ' . $database->{host};
                say '-- user: ' . $database->{user};
                say '-- password: ' . $database->{password};
                say '';
                say '-- datbase names to backup:';

                for my $db_name (@{ $database->{database_names} }) {
                    say '---- '  . $db_name;
                }

                say '';

                say '-- paths where to backup:';

                for my $path (@{ $database->{paths} }) {
                    say '---- '  . $path;
                }
            }
        }
    } else {
        say "remotely is not enabled";
    }
}

generate_backup_localy($data_config);
say '';
say '';
generate_backup_remotely($data_config);
