require 'json'
require 'tmpdir'
require 'tempfile'
require 'digest'
require 'timeout'
abort 'usage: ruby measure.rb BASELINE CANDIDATE OUTPUT_JSON [ROUNDS]' unless (3..4).cover?(ARGV.size)
abort 'this resource measurement requires macOS /usr/bin/time -l' unless RUBY_PLATFORM.include?('darwin')
binaries={baseline:File.expand_path(ARGV[0]),candidate:File.expand_path(ARGV[1])}
output_path=File.expand_path(ARGV[2])
rounds=Integer(ARGV[3]||'11')
abort 'rounds must be between 3 and 101' unless (3..101).cover?(rounds)
Dir.mktmpdir('seq-retention-') do |dir|
[[64,4096],[512,8192]].each do |count,width|
  File.open("#{dir}/turns-#{count}.jsonl",'w') do |file|
    file.puts({timestamp:'2026-07-26T10:00:00Z',type:'session_meta',payload:{id:'synthetic-benchmark',cwd:'/synthetic/repo'}}.to_json)
    count.times do |index|
      [
        {type:'task_started',turn_id:"turn-#{index}"},
        {type:'user_message',message:"question-#{index}-"+'x'*width},
        {type:'agent_message',message:"answer-#{index}-"+'y'*width},
        {type:'task_complete',turn_id:"turn-#{index}"}
      ].each{|payload|file.puts({timestamp:'2026-07-26T10:00:01Z',type:'event_msg',payload:payload}.to_json)}
    end
  end
end
cases=[
  {name:'turns-64-projected',source:"#{dir}/turns-64.jsonl",spec:{dataset:'turns',select:['turn_id','status'],limit:2048}},
  {name:'turns-512-projected',source:"#{dir}/turns-512.jsonl",spec:{dataset:'turns',select:['turn_id','status'],limit:2048}},
  {name:'messages-512-projected',source:"#{dir}/turns-512.jsonl",spec:{dataset:'messages',select:['source_event_id','turn_index','role'],limit:2048}},
  {name:'events-512-projected',source:"#{dir}/turns-512.jsonl",spec:{dataset:'source_events',select:['source_event_id','event_type','turn_index'],limit:4096}},
  {name:'turns-64-full',source:"#{dir}/turns-64.jsonl",spec:{dataset:'turns',limit:2048}}
]
records=[]
def capture_bounded(binary,test)
  Tempfile.create('seq-out') do |out|
    Tempfile.create('seq-time') do |err|
      started=Process.clock_gettime(Process::CLOCK_MONOTONIC,:nanosecond)
      pid=Process.spawn('/usr/bin/time','-l',binary,'query','--path',test[:source],'--spec',test[:spec].to_json,out:out,err:err,pgroup:true)
      status=nil
      begin
        Timeout.timeout(10) { status=Process.waitpid2(pid)[1] }
      ensure
        unless status
          begin
            Process.kill('KILL',-pid)
          rescue Errno::ESRCH
          end
          Process.waitpid(pid)
        end
      end
      elapsed=Process.clock_gettime(Process::CLOCK_MONOTONIC,:nanosecond)-started
      raise 'CLI measurement exceeded ten seconds' unless status
      out.rewind
      err.rewind
      [out.read,err.read,status,elapsed]
    end
  end
end

def observe(binary,test)
  stdout,stderr,status,elapsed=capture_bounded(binary,test)
  raise stderr unless status.success?
  rss=stderr.match(/^\s*(\d+)\s+maximum resident set size$/)&.captures&.first
  raise "missing RSS: #{stderr}" unless rss
  {wall_ns:elapsed,maximum_resident_set_bytes:rss.to_i,stdout_bytes:stdout.bytesize,stdout_sha256:Digest::SHA256.hexdigest(stdout),time_raw:stderr}
end
cases.each{|test|binaries.each_value{|binary|observe(binary,test)}}
rounds.times do |round|
  cases.rotate(round%cases.size).each do |test|
    order=round.even? ? binaries.to_a : binaries.to_a.reverse
    pair=order.to_h{|name,binary|[name,observe(binary,test)]}
    raise "output mismatch #{test[:name]}" unless pair[:baseline][:stdout_sha256]==pair[:candidate][:stdout_sha256]
    records<<{round:round,case:test[:name],observations:pair}
  end
end
summary=cases.map do |test|
  item={case:test[:name],fixture_bytes:File.size(test[:source]),fixture_sha256:Digest::SHA256.file(test[:source]).hexdigest,spec:test[:spec]}
  [:wall_ns,:maximum_resident_set_bytes].each do |metric|
    group=binaries.keys.to_h do |name|
      sorted=records.select{|r|r[:case]==test[:name]}.map{|r|r[:observations][name][metric]}.sort
      [name,{median:sorted[sorted.size/2],min:sorted.first,max:sorted.last}]
    end
    item[metric]=group.merge(improvement_percent:100.0*(group[:baseline][:median]-group[:candidate][:median])/group[:baseline][:median])
  end
  item
end
report={baseline_revision:'8e470a24b533dba479f39f7ae3cc7f07b5fc5aeb',zig:'0.17.0',optimize:'fast',rounds:rounds,ordering:'alternating baseline/candidate; rotating case order; one warmup each',environment:{os:`sw_vers -productVersion`.strip,architecture:`uname -m`.strip,cpu:`sysctl -n machdep.cpu.brand_string`.strip,shared_with_unrelated_workloads:true},binaries:binaries.to_h{|k,p|[k,{sha256:Digest::SHA256.file(p).hexdigest}]},summary:summary,samples:records}
File.write(output_path,JSON.pretty_generate(report))
puts JSON.pretty_generate(summary)
end
