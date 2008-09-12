#! /usr/bin/ruby
# To do: real error checking
# !!!WARNING!!! 
# Read this script before running it! It modifies files, adds directories, and I'm not responsible if it accidentally deletes something on your machine!

# REQUIREMENTS: you should have a recent version of git installed, as well as all the required gems for CommunityEngine.
# If you're using the EC2 CommunityEngineServer image, you're ready to go. Just log into your server as root, and run this script:
#  ruby ce_setup.rb


require 'rubygems'
require 'open-uri'
require 'timeout'

class CeSetup
  attr_accessor :application, :db_user, :db_pass, :git_repository_directory, :hostname
  
  def initialize(application, db_pass)    
    self.application = application
    self.db_user = application
    self.db_pass = db_pass
  end
  
  def setup
    unless self.application && self.db_pass
      raise 'Sorry, you must include an application name'     
       
    end
    if self.application.length > 15
      raise 'Sorry, application name must be shorter that 16 characters'
    end
    
    if File.exists?(repo_path)
      raise "Sorry, the specified repository already exists: #{repo_path}"
    end
    
    say "Setting up the system for CE installation"    

    create_git_repo
    create_rails_app
    add_plugins
    modify_environment_files
    add_application_yml
    remove_index_file    
    generate_migrations
    migrate
    setup_deployment
    # generate_keys if confirm('Generate root ssh keys for deployment?') #if on EC2, create root keys so the server can depoy to itself
    deploy_cold if confirm('Deploy application?')
    # make_motd_file # if on EC2
  end
  
  def make_motd_file
    message = <<EOF
    ******* Welcome to your CommunityEngine EC2 Instance. **************

    Your application repository can be found in #{repo_path}

    The deployed application is in /mnt/apps/#{application}/

    The NGINX config was generated by capistrano and is in /etc/rails/#{application}.conf

    Other useful locations:

    /etc/mongrel_cluster
    /etc/cron.daily/#{application}.cron
EOF

    say "Replacing MOTD file"
    `echo '#{message}' > /etc/motd`    
  end
  
  def add_application_yml
    yml = <<EOF
    community_name: "#{application}"
EOF

    say "Adding application.yml file"
    `echo '#{yml}' > #{repo_path}/config/application.yml`    
  
    commit_with_message('Added application.yml')
  end
    
  def remove_index_file
    cmd = "rm #{repo_path}/public/index.html"
    system(cmd)
    commit_with_message('Removed index file')
  end
  
  # def get_meta_data(token)
  #   open("http://169.254.169.254/latest/meta-data/#{token}").read    
  # end
  
  def public_hostname
    self.hostname ||= ask("Enter the hostname where you will be deploying this application (i.e. example.com). If you're using this on EC2, enter the EC2 instance hostname (i.e. ec2-000-000-000-000.compute-1.amazonaws.com)")
    # self.hostname ||= get_meta_data('public-hostname')    
    # if on an EC2 instance, we can get this from the server itself, instead of having to ask the user for it
    
    self.hostname
  end
    
  def repo_path
    "#{git_repository_directory || '/mnt/git'}/#{application}.git"    
  end
  
  def create_git_repo
    say "Creating empty git repository in #{repo_path}"
    `mkdir -p #{repo_path} && cd #{repo_path} && git init`
  end
  
  def create_rails_app
    say "Initalizing blank Rails app in #{repo_path}"
    out = `cd #{repo_path} && rails .`    
    
    add_git_ignore
    commit_with_message("Initial import of Rails application")
  end
  
  def add_git_ignore
    git_ignore = <<EOF
.DS_Store
tmp
log/*.log
public/plugin_assets
db/schema.rb
public/assets/*
public/photos/*
public/homepage_features/*
coverage/*
EOF

    say "Adding .gitignore file"
    `echo '#{git_ignore}' > #{repo_path}/.gitignore`    
  end
  
  def add_plugins
    say "Adding Engines plugin and CE plugin"
    engines_cmd = "cd #{repo_path} && ./script/plugin --verbose install git://github.com/lazyatom/engines.git"
    ce_plugin_cmd = "cd #{repo_path} && git submodule add git://github.com/bborn/communityengine.git vendor/plugins/community_engine && git submodule init && git submodule update"

    system(engines_cmd)
    system(ce_plugin_cmd)

    commit_with_message("Adding engines and community_engine plugins")
  end
  
  def modify_environment_files
    environment_file = "#{repo_path}/config/environment.rb"
    say "Modifying your environment.rb and environments files to work with CE"

    line = "require File.join(File.dirname(__FILE__), 'boot')"
    new_line = "require File.join(File.dirname(__FILE__), '../vendor/plugins/engines/boot')"
    add_line_to_file_after(environment_file, line, new_line)

    new_lines = <<EOF
  config.plugins = [:engines, :community_engine, :white_list, :all]
  config.plugin_paths += ["\#{RAILS_ROOT}/vendor/plugins/community_engine/engine_plugins"]
EOF
    add_line_to_file_after(environment_file, 'Rails::Initializer.run do |config|', new_lines)

    ce_boot_line = "\n require \"\#{RAILS_ROOT}/vendor/plugins/community_engine/engine_config/boot.rb\""
    append_to_file(environment_file, ce_boot_line)

    say "Modifying environment files ..."

    ['development', 'test'].each do |env|
      append_to_file("#{repo_path}/config/environments/#{env}.rb", "\nAPP_URL = \"http://localhost:3000\"")
    end
    append_to_file("#{repo_path}/config/environments/production.rb", "\nAPP_URL = \"http://#{public_hostname}\"")

    say "Adding CE routes to the application"
    ce_routes_line = "  map.from_plugin :community_engine"
    add_line_to_file_after("#{repo_path}/config/routes.rb", 'ActionController::Routing::Routes.draw do |map|', ce_routes_line)    
  end
  
  def generate_migrations
    say "Generating CE plugin migrations"
    generate_migrations_cmd = "cd #{repo_path} && ruby script/generate plugin_migration"
    system(generate_migrations_cmd)   
    commit_with_message("CE migrations added")    
  end
  
  def migrate
    say "Migrating"
    migrate_cmd = "cd #{repo_path} && rake db:migrate"
    system(migrate_cmd)
  end
  
  def setup_deployment
    say "Setting up deployment"
    cmd = "cd #{repo_path} && capify . && rake community_engine:generate_deploy_script application=#{application} repo=#{repository_url} db_user=#{db_user} db_pass=#{db_pass} hostname=#{public_hostname}"
    system(cmd)
  end
  
  def deploy_cold
    say "Deploying"
    cmd = "cd #{repo_path} && cap deploy:setup && cap deploy:mysql_setup && cap deploy:cold && cap restart_web"
    system(cmd)
  end
  
  def generate_keys
    say 'generating ssh keys'
    cmd = "ssh-keygen -t rsa -f /root/.ssh/id_rsa -N ''"
    system(cmd)
    
    say 'Adding ssh key to authorized_keys'
    cmd = "cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys"    
    system(cmd)

    cmd = "chmod 0600 /root/.ssh/authorized_keys"    
    system(cmd)
  end
  
  protected
  
    def repository_url
      "ssh://#{public_hostname}#{repo_path}"
    end
    
    def gsub_file(path, regexp, *args, &block)
      content = File.read(path).gsub(regexp, *args, &block)
      File.open(path, 'wb') { |file| file.write(content) }
    end

    def add_line_to_file_after(file, line, new_line)
      gsub_file file, /(#{Regexp.escape(line)})/mi do |match|
        "#{match}\n#{new_line}\n"
      end  
    end

    def append_to_file(file, string)
      cmd = "echo '#{string}' >> #{file}"  
      system(cmd)
    end

    def commit_with_message(message)
      say "Committing to repository ..."
      `cd #{self.repo_path} && git add . && git commit -a -m '#{message}'`
    end  
    
    def say(message)
      puts " [CE SETUP] #{message} \n "
    end
  
end

# If running this on startup on EC2, we can pass in the required variables as launch parameters (ec2-run-instance i-xxxx -d 'application=example&db_pass=foobar)
# this method makes it possible to parse them from a string
# def parse_userdata(string)
#   m = proc {|_,o,n|o.merge(n,&m)rescue(o.to_a<<n)}
#   string.split(/[&;]/n).
#      inject({}) { |h,p| 
#        k, v = p.split('=',2)
#        h.merge(
#          k.split(/[\]\[]+/).reverse.
#            inject(v) { |x,i| {i=>x} },&m)
#      }
# end

# Get user data from the EC2 instance (returns user_data['application'] and user_data['db_pass'])
# user_data = Timeout::timeout(5) do
#   parse_userdata( open("http://169.254.169.254/1.0/user-data").read )
# end
# puts "User data fetched: #{user_data.inspect}"


# Just some utilities
def ask(string)
  puts "#{string}:"
  gets.chomp!
end
def confirm(message)
  puts "#{message} (Y/N): "
  input = gets.chomp
  if input =~ /^[yY]/
    true
  else
    false
  end
 end


application = ask('Please enter the name of your application (must be less than 16 characters, no spaces or special chars)').downcase
db_password = ask('Enter a database password to be used with this application')

ce = CeSetup.new(application, db_password)
ce.git_repository_directory = ask('Please enter the absolute path where you want to store your repository (defaults to /mnt/git/)')
ce.setup