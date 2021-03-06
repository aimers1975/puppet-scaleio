#!/opt/puppet/bin/ruby

require "trollop"
require "json"
require "timeout"
require "pathname"

puppet_dir = File.join(Pathname.new(__FILE__).parent.parent,'lib','puppet')
require "%s/scaleio/transport" % [puppet_dir]

@opts = Trollop::options do
  opt :server, "ScaleIO gateway", :type => :string, :required => true
  opt :port, "ScaleIO gateway port", :default => 443
  opt :username, "ScaleIO gateway username", :type => :string, :required => true
  opt :password, "ScaleIO gateway password", :type => :string, :default => ENV["PASSWORD"]
  opt :timeout, "ScaleIO gateway connection timeout", :type => :integer, :default => 300, :required => false
  opt :credential_id, "dummy value for ASM, not used"
  opt :output, "Location of the file where facts file needs to be created", :type => :string, :required => false
end

def collect_scaleio_facts
  facts = {:protection_domain_list => []}
  facts[:certname] = "scaleio-%s" % [@opts[:server]]
  facts[:name] = "scaleio-%s" % [@opts[:server]]
  facts[:update_time] = Time.now
  facts[:device_type] = "script"

  # ScaleIO MDM is not configured
  # Need to return basic information
  if scaleio_cookie == "NO MDM"
    facts = {
      :general => { "name" => facts[:certname] },
      :statistics => {},
      :sdc_list => [],
      :protection_domain_list => [],
      :fault_sets => []
    }

    return facts
  end

  scaleio_system = scaleio_systems[0]

  facts[:general] = scaleio_system
  facts[:general]["name"] ||= facts[:certname]

  facts[:statistics] = scaleio_system_statistics(scaleio_system)
  facts[:sdc_list] = scaleio_sdc(scaleio_system)
  protection_domains(scaleio_system).each do |protection_domain|
    pd = {:general => protection_domain,
          :statistics => protection_domain_statistics(protection_domain),
          :storage_pool_list => protection_domain_storage_pools(protection_domain),
          :sds_list => protection_domain_sdslist(protection_domain)}
    pd[:storage_pool_list].each do |storage_pool|
      storage_pool[:statistics] = storage_pool_statistics(storage_pool)
      storage_pool[:disk_list] = storage_pool_disks(storage_pool)
      storage_pool[:volume_list] = storage_pool_volumes(storage_pool)
    end
    facts[:protection_domain_list] << pd
  end
  facts[:fault_sets] = scaleio_faultsets(scaleio_system)
  facts
end

def scaleio_systems
  url = transport.get_url("/api/types/System/instances")
  transport.post_request(url, {}, "get") || []
end

def scaleio_system_statistics(scaleio_system)
  end_point = "/api/instances/System::%s/relationships/Statistics" % [scaleio_system["id"]]
  url = transport.get_url(end_point)
  transport.post_request(url, {}, "get") || []
end

def scaleio_sdc(scaleio_system)
  sdc_url = "/api/instances/System::%s/relationships/Sdc" % [scaleio_system["id"]]
  url = transport.get_url(sdc_url)
  transport.post_request(url, {}, "get") || []
end

def protection_domains(scaleio_system)
  pd_url = "/api/instances/System::%s/relationships/ProtectionDomain" % [scaleio_system["id"]]
  url = transport.get_url(pd_url)
  transport.post_request(url, {}, "get") || []
end

def protection_domain_statistics(protection_domain)
  end_point = "/api/instances/ProtectionDomain::%s/relationships/Statistics" % [protection_domain["id"]]
  url = transport.get_url(end_point)
  transport.post_request(url, {}, "get") || []
end

def protection_domain_storage_pools(protection_domain)
  sp_url = "/api/instances/ProtectionDomain::%s/relationships/StoragePool" % [protection_domain["id"]]
  url = transport.get_url(sp_url)
  transport.post_request(url, {}, "get") || []
end

def protection_domain_sdslist(protection_domain)
  sp_url = "/api/instances/ProtectionDomain::%s/relationships/Sds" % [protection_domain["id"]]
  url = transport.get_url(sp_url)
  transport.post_request(url, {}, "get") || []
end

def storage_pool_volumes(storage_pool)
  sp_url = "/api/instances/StoragePool::%s/relationships/Volume" % [storage_pool["id"]]
  url = transport.get_url(sp_url)
  transport.post_request(url, {}, "get") || []
end

def storage_pool_statistics(storage_pool)
  end_point = "/api/instances/StoragePool::%s/relationships/Statistics" % [storage_pool["id"]]
  url = transport.get_url(end_point)
  transport.post_request(url, {}, "get") || []
end

def storage_pool_disks(storage_pool)
  sp_url = "/api/instances/StoragePool::%s/relationships/Device" % [storage_pool["id"]]
  url = transport.get_url(sp_url)
  transport.post_request(url, {}, "get") || []
end

def scaleio_faultsets(scaleio_system)
  faultset_url = "/api/types/FaultSet/instances?systemId=%s" % [scaleio_system["id"]]
  url = transport.get_url(faultset_url)
  transport.post_request(url, {}, "get") || []
end

def transport
  @transport ||= Puppet::ScaleIO::Transport.new(@opts)
end

def scaleio_cookie
  @scaleio_cookie ||= transport.get_scaleio_cookie
end

facts = {}
begin
  Timeout.timeout(@opts[:timeout]) do
    facts = collect_scaleio_facts.to_json
  end
rescue Timeout::Error
  puts "Timed out trying to gather ScaleIO Inventory"
  exit 1
rescue Exception => e
  puts "#{e}\n#{e.backtrace.join("\n")}"
  exit 1
else
  if facts.empty?
    puts "Could not get updated facts"
    exit 1
  else
    puts "Successfully gathered inventory."
    if @opts[:output]
      File.write(@opts[:output], JSON.pretty_generate(JSON.parse(facts)))
    else
      results ||= {}
      scaleio_cache = "/opt/Dell/ASM/cache"
      Dir.mkdir(scaleio_cache) unless Dir.exists? scaleio_cache
      file_path = File.join(scaleio_cache, "#{opts[:server]}.json")
      File.write(file_path, results) unless results.empty?
    end
  end
end
