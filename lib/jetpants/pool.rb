require 'json'
require 'db'

module Jetpants
  
  # a Pool represents a group of database instances (Jetpants::DB objects).
  #
  # The default implementation assumes that a Pool contains:
  # * 1 master
  # * 0 or more slaves, falling into one of these categories:
  #   * active slaves (actively taking production read queries)
  #   * standby slaves (for HA, promotable if a master or active slave fails + used to clone new replacements)
  #   * backup slaves (dedicated for backups and background jobs, never put into prod, potentially different hardware spec)
  #
  # Plugins may of course override this extensively, to support different
  # topologies, such as master-master trees.
  #
  # Many of these methods are only useful in conjunction with an asset-tracker /
  # configuration-generator plugin
  class Pool
    include CallbackHandler

    # human-readable String name of pool
    attr_reader   :name
    
    # Jetpants::DB object that is the pool's master
    attr_reader   :master
    
    # Array of strings containing other equivalent names for this pool
    attr_reader   :aliases
    
    # Can be used to store a name that refers to just the active_slaves, for
    # instance if your framework isn't smart enough to know about master/slave
    # relationships.  Safe to leave as nil otherwise. Has no effect in Jetpants,
    # but an asset tracker / config generator plugin may include this in the
    # generated config file.
    attr_accessor :slave_name
    
    # Hash mapping DB object => weight, for active (read) slaves. Default weight
    # is 100. Safe to leave at default if your app framework doesn't support
    # different weights for individual read slaves. Weights have no effect inside
    # Jetpants, but any asset tracker / config generator plugin can carry them
    # through to the config file.
    attr_reader   :active_slave_weights
    
    # If the master also receives read queries, this stores its weight. Set to 0
    # if the master does not receive read queries (which is the default). This
    # has no effect inside of Jetpants, but can be used by an asset tracker /
    # config generator plugin to carry the value through to the config file.
    attr_accessor :master_read_weight
    
    def initialize(name, master)
      @name = name
      @slave_name = false
      @aliases = []
      @master = master.to_db
      @master_read_weight = 0
      @active_slave_weights = {}
    end
    
    # Returns all slaves, or pass in :active, :standby, or :backup to receive slaves
    # just of a particular type
    def slaves(type=false)
      case type
      when :active  then active_slaves
      when :standby then standby_slaves
      when :backup  then backup_slaves
      when false    then @master.slaves
      else []
      end
    end
    
    # Returns an array of Jetpants::DB objects.
    # Active slaves are ones that receive read queries from your application.
    def active_slaves
      @master.slaves.select {|sl| @active_slave_weights[sl]}
    end
    
    # Returns an array of Jetpants::DB objects.
    # Standby slaves do not receive queries from your application. These are for high availability.
    # They can be turned into active slaves or even the master, and can also be used for cloning
    # additional slaves.
    def standby_slaves
      @master.slaves.reject {|sl| @active_slave_weights[sl] || sl.for_backups?}
    end
    
    # Returns an array of Jetpants::DB objects.
    # Backup slaves are never promoted to active or master. They are for dedicated backup purposes.
    # They may be a different/cheaper hardware spec than other slaves.
    def backup_slaves
      @master.slaves.reject {|sl| @active_slave_weights[sl] || !sl.for_backups?}
    end
    
    # returns a flat array of all Jetpants::DB objects in the pool: the master and
    # all slaves of all types.
    def nodes
      [master, slaves].flatten.compact
    end
    
    # Informs Jetpants that slave_db is an active slave. Potentially used by 
    # plugins, such as in Topology at start-up time.
    def has_active_slave(slave_db, weight=100)
      slave_db = slave_db.to_db
      raise "Attempt to mark a DB as its own active slave" if slave_db == @master
      @active_slave_weights[slave_db] = weight
    end
    
    # Turns a standby slave into an active slave, giving it the specified read weight.
    # Syncs the pool's configuration afterwards. It's up to your asset tracker plugin to
    # actually do something with this information.
    def mark_slave_active(slave_db, weight=100)
      raise "Attempt to make a backup slave be an active slave" if slave_db.for_backups?
      has_active_slave slave_db, weight
      sync_configuration
    end
    
    # Turns an active slave into a standby slave. Syncs the pool's configuration afterwards.
    # It's up to your asset tracker plugin to actually do something with this information.
    def mark_slave_standby(slave_db)
      slave_db = slave_db.to_db
      raise "Cannot call mark_slave_standby on a master" if slave_db == @master
      @active_slave_weights.delete(slave_db)
      sync_configuration
    end
    
    # Remove a slave from a pool entirely. This is destructive, ie, it does a
    # RESET SLAVE on the db.
    # Note that a plugin may want to override this (or implement after_remove_slave!)
    # to actually sync the change to an asset tracker, depending on how the plugin
    # implements Pool#sync_configuration. (If the implementation makes sync_configuration
    # work by iterating over the pool's current slaves, it won't see any slaves that have
    # been removed.)
    def remove_slave!(slave_db)
      raise "Slave is not in this pool" unless slave_db.pool == self
      slave_db.disable_monitoring
      slave_db.stop_replication
      slave_db.repl_binlog_coordinates # displays how far we replicated, in case you need to roll back this change manually
      slave_db.disable_replication!
    end
    
    # Informs this pool that it has an alias. A pool may have any number of aliases.
    def add_alias(name)
      if @aliases.include? name
        false
      else
        @aliases << name
        true
      end
    end
    
    # Displays a summary of the pool's members. This outputs immediately instead
    # of returning a string, so that you can invoke something like:
    #    Jetpants.topology.pools.each &:summary 
    # to easily display a summary.
    def summary(extended_info=false)
      probe

      alias_text = @aliases.count > 0 ? '  (aliases: ' + @aliases.join(', ') + ')' : ''
      data_size = @master.running? ? "[#{master.data_set_size(true)}GB]" : ''
      print "#{name}#{alias_text}  #{data_size}\n"
      
      if extended_info
        details = {}
        nodes.concurrent_each do |s|
          if !s.running?
            details[s] = {coordinates: ['unknown'], lag: 'N/A'}
          elsif s == @master
            details[s] = {coordinates: s.binlog_coordinates(false), lag: 'N/A'}
          else
            lag = s.seconds_behind_master
            lag_str = lag.nil? ? 'NULL' : lag.to_s + 's'
            details[s] = {coordinates: s.repl_binlog_coordinates(false), lag: lag_str}
          end
        end
      end
      
      binlog_pos = extended_info ? details[@master][:coordinates].join(':') : ''
      print "\tmaster          = %-13s %-30s %s\n" % [@master.ip, @master.hostname, binlog_pos]
      
      [:active, :standby, :backup].each do |type|
        slave_list = slaves(type)
        slave_list.sort.each_with_index do |s, i|
          binlog_pos = extended_info ? details[s][:coordinates].join(':') : ''
          slave_lag = extended_info ? "lag=#{details[s][:lag]}" : ''
          print "\t%-7s slave #{i + 1} = %-13s %-30s %-26s %s\n" % [type, s.ip, s.hostname, binlog_pos, slave_lag]
        end
      end
      true
    end
    
    # Demotes the pool's existing master, promoting a slave in its place.
    def master_promotion!(promoted)
      demoted = @master
      raise "Demoted node is already the master of this pool!" if demoted == promoted
      raise "Promoted host is not in the right pool!" unless demoted.slaves.include?(promoted)
      
      output "Preparing to demote master #{demoted} and promote #{promoted} in its place."
      
      # If demoted machine is available, confirm it is read-only and binlog isn't moving,
      # and then wait for slaves to catch up to this position
      if demoted.running?
        demoted.enable_read_only! unless demoted.read_only?
        raise "Unable to enable global read-only mode on demoted machine" unless demoted.read_only?
        coordinates = demoted.binlog_coordinates
        raise "Demoted machine still taking writes (from superuser or replication?) despite being read-only" unless coordinates == demoted.binlog_coordinates
        demoted.slaves.concurrent_each do |s|
          while true do
            sleep 1
            break if s.repl_binlog_coordinates == coordinates
            output "Still catching up to coordinates of demoted master"
          end
        end
      
      # Demoted machine not available -- wait for slaves' binlogs to stop moving
      else
        demoted.slaves.concurrent_each do |s|
          progress = s.repl_binlog_coordinates
          while true do
            sleep 1
            break if s.repl_binlog_coordinates == progress
            s.output "Still catching up on replication"
          end
        end
      end
      
      # Stop replication on all slaves
      replicas = demoted.slaves.dup
      replicas.each do |s|
        s.pause_replication if s.replicating?
      end
      raise "Unable to stop replication on all slaves" if replicas.any? {|s| s.replicating?}
      
      user, password = promoted.replication_credentials.values
      log,  position = promoted.binlog_coordinates
      
      # reset slave on promoted, and make sure read_only is disabled
      promoted.disable_replication!
      promoted.disable_read_only!
      
      # gather our new replicas
      replicas.delete promoted
      replicas << demoted if demoted.running?
      
      # perform promotion
      replicas.each do |r|
        r.change_master_to promoted, user: user, password: password, log_file: log, log_pos: position
      end

      # ensure our replicas are configured correctly by comparing our staged values to current values of replicas
      promoted_replication_config = {
        master_host: promoted.ip,
        master_user: user,
        master_log_file:  log,
        exec_master_log_pos: position.to_s
      }
      replicas.each do |r|
        promoted_replication_config.each do |option, value|
          raise "Unexpected slave status value for #{option} in replica #{r} after promotion" unless r.slave_status[option] == value
        end
        r.resume_replication unless r.replicating?
      end
      
      # Update the pool
      # Note: if the demoted machine is not available, plugin may need to implement an
      # after_master_promotion! method which handles this case in configuration tracker
      @active_slave_weights.delete promoted # if promoting an active slave, remove it from read pool
      @master = promoted
      sync_configuration
      Jetpants.topology.write_config
      
      output "Promotion complete. Pool master is now #{promoted}."
      
      replicas.all? {|r| r.replicating?}
    end
    
    # Informs your asset tracker about any changes in the pool's state or members.
    # Plugins should override this, or use before_sync_configuration / after_sync_configuration
    # callbacks, to provide an implementation of this method.
    def sync_configuration
    end
    
    # Callback to ensure that a sync'ed pool is already in Topology.pools
    def before_sync_configuration
      unless Jetpants.topology.pools.include? self
        Jetpants.topology.pools << self
      end
    end
    
    # Returns the name of the pool.
    def to_s
      @name
    end
    
    # Displays the provided output, along with information about the current time,
    # and self (the name of this Pool)
    def output(str)
      str = str.to_s.strip
      str = nil if str && str.length == 0
      str ||= "Completed (no output)"
      output = Time.now.strftime("%H:%M:%S") + " [#{self}] "
      output << str
      print output + "\n"
      output
    end
    
    # Jetpants::Pool proxies missing methods to the pool's @master Jetpants::DB instance.
    def method_missing(name, *args, &block)
      if @master.respond_to? name
        @master.send name, *args, &block
      else
        super
      end
    end
    
    def respond_to?(name, include_private=false)
      super || @master.respond_to?(name)
    end
    
  end
end
