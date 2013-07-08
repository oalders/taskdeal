package Taskdeal::Client;
use Mojo::Base -base;

use FindBin;
use Config::Tiny;
use Taskdeal::Log;
use Taskdeal::Client::Manager;
use Mojo::UserAgent;
use Mojo::IOLoop;
use Sys::Hostname 'hostname';
use Archive::Tar;
use File::Path qw/mkpath rmtree/;

has 'home';

# Reconnet interval
my $reconnect_interval = 5;

sub start {
  my $self = shift;
  
  # Home
  my $home = $self->home;
  
  # Log
  my $log = Taskdeal::Log->new(path => "$home/log/taskdeal-client.log");

  # Util
  my $manager = Taskdeal::Client::Manager->new(home => $home, log => $log);

  # Config
  my $ct = Config::Tiny->new;
  my $config_file = "$home/taskdeal-client.conf";
  my $config = $ct->read($config_file);
  die "Config read error $config_file: " . $ct->errstr if $ct->errstr;

  # Config for development
  my $config_my_file = "$home/taskdeal-client.my.conf";
  if (-f $config_my_file) {
    my $config_my = $ct->read($config_my_file);
    die "Config read error: $config_my_file" . $ct->errstr if $ct->errstr;

    # Merge config
    for my $section (keys %$config_my) {
      $config->{$section}
        = {%{$config->{$section} || {}}, %{$config_my->{$section} || {}}};
    }
  }

  # User Agent
  my $ua = Mojo::UserAgent->new;
  $ua->inactivity_timeout(0);

  # Server URL
  my $server_host = $config->{server}{host} || 'localhost';
  my $server_url = "ws://$server_host";
  $ENV{TASKDEAL_SERVER_PORT} = 3000;
  my $server_port = $ENV{TASKDEAL_SERVER_PORT} || $config->{server}{port} || '10040';
  $server_url .= ":$server_port";

  # Connect to server
  my $websocket_cb;
  $websocket_cb = sub {
    $ua->websocket($server_url => sub {
      my ($ua, $tx) = @_;
      
      # Web socket connection success
      if ($tx->is_websocket) {
        $log->info("Connect to $server_url.");
        
        # Send client information
        my $hostname = hostname;
        my $current_role = $manager->current_role;
        my $name = $config->{client}{name};
        my $group = $config->{client}{group};
        my $description = $config->{client}{description};
        $tx->send({json => {
          type => 'client_info',
          current_role => $current_role,
          name => $name,
          group => $group,
          description => $description
        }});
        
        # Receive JSON message
        $tx->on(json => sub {
          my ($tx, $hash) = @_;
          
          my $type = $hash->{type} || '';
          if ($type eq 'sync') {
            my $role_name = $hash->{role_name};
            my $role_tar = $hash->{role_tar};
            
            $log->info('Receive sync command');
            
            if (open my $fh, '<', \$role_tar) {
              my $tar = Archive::Tar->new;
              my $role_dir = "$home/client/role/$role_name";
              mkpath $role_dir;
              $tar->setcwd($role_dir);
              if ($tar->read($fh)) {
                eval { $manager->cleanup_role };
                if ($@) {
                  my $message = "Error: cleanup role: $@";
                  $log->erorr($message);
                  $tx->send({json => {type => 'sync_result', ok => 0, message => $message}});
                }
                else {
                  $tar->extract;
                  $tx->send({json => {type => 'sync_result', ok => 1}});
                }
              }
              else {
                my $message = "Error: Can't read role tar: $!";
                $log->erorr($message);
                $tx->send({json => {type => 'sync_result', ok => 0, message => $message}});
              }
            }
            else {
              my $message = "Error: Can't open role tar: $!";
              $log->erorr($message);
              $tx->send({json => {type => 'sync_result', ok => 0, message => $message}});
            }
          }
          elsif ($type eq 'task') {
            my $work_dir = "$home/client/role";
            
            if (chdir $work_dir) {
              my $command = $hash->{command};
              my $args = $hash->{args} || [];
              
              if (system("./$command", @$args) == 0) {
                my $status = `echo $?`;
                if (($status || '') =~ /^0/) {
                  my $message = "$type success. Command $command @$args";
                  $log->info($message);
                  $tx->send({json => {message => $message, success => 1}});
                }
                else {
                  my $message = "$type fail. Command $command @$args. Return bad status.";
                  $log->error($message);
                  $tx->send({json => {message => $message, success => 0}});
                }
              } else {
                my $message = "$type fail. Command $command @$args. Command fail.";
                $log->error($message);
                $tx->send({json => {message => $message, success => 0}});
              }
            }
            else {
              my $message = "$type fail. Can't change directory $work_dir: $!";
              $log->error($message);
              $tx->send({json => {message => $message, success => 0}});
            }
          }
          else {
            my $message = "Unknown type $type";
            $log->error($message);
            $tx->send({json => {message => "Unknown type $type", success => 0}});
          }
        });
        
        # Finish websocket connection
        $tx->on(finish => sub {
          $log->info("Disconnected.");
          
          # Reconnect to server
          Mojo::IOLoop->timer($reconnect_interval => sub { goto $websocket_cb });
        });
      }
      
      # Web socket connection fail
      else {
        $log->error("Can't connect to server: $server_url.");
        
        # Reconnect to server
        Mojo::IOLoop->timer($reconnect_interval => sub { goto $websocket_cb });
      }
    });
  };
  $websocket_cb->();

  Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
}
