namespace :control_center do
  namespace :ansible do
    desc "Fail stale Ansible runs and executor utility tasks"
    task reap: :environment do
      result = ControlCenter::Ansible::RunReaper.call
      puts "Reaped #{result.runs} Ansible runs and #{result.tasks} executor tasks."
    end
  end
end
