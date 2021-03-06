class BuildSystemBase
  attr_reader :recipe, :build_log, :lock, :set_lock_called

  abstract_method :up
  abstract_method :provision
  abstract_method :halt
  abstract_method :is_busy?
  abstract_method :get_lockfile

  def initialize(recipe)
    @recipe = recipe
    @build_log = recipe.basepath + "/" + Dice::META + "/" + Dice::BUILD_LOG
    recipe.change_working_dir
    @lock = get_lockfile
    @set_lock_called = false
    post_initialize
  end

  def post_initialize
    nil
  end

  def is_building?
    building = true
    begin
      Command.run("fuser", build_log, :stdout => :capture)
    rescue Cheetah::ExecutionFailed => e
      building = false
    end
    building
  end

  def is_locked?
    if semaphore.getval(semaphore_id) >= 1
      return true
    end
    false
  end

  def set_lock
    semaphore.setval(semaphore_id, 1)
    @set_lock_called = true
    get_lock_key
  end

  def release_lock
    semaphore.remove(semaphore_id) if set_lock_called
  end

  def prepare_job
    @job ||= Job.new(self)
  end

  def archive_job_result(job_result_dir, archive_filename)
    result_command = "tar -C #{job_result_dir} -c ."
    result = File.open(archive_filename, "w")
    begin
      Command.run(
        job_builder_command(result_command),
        :stdout => result
      )
    rescue Cheetah::ExecutionFailed => e
      result.close
      raise Dice::Errors::ResultRetrievalFailed.new(
        "Archiving result failed with: #{e.stderr}"
      )
    end
    result.close
  end

  def job_builder_command(action)
    command = [
      "ssh",
      "-o", "StrictHostKeyChecking=no",
      "-p", port,
      "-i", private_key_path,
      "#{user}@#{host}",
      "sudo #{action}"
    ]
    command
  end

  def import_build_options
    build_options_file =
      recipe.basepath + "/" + Dice::META + "/" + Dice::BUILD_OPTS_FILE
    begin
      build_options = File.open(build_options_file, "rb")
      options = Marshal.load(build_options)
      build_options.close
      options.marshal_dump.each do |key, value|
        Dice.option[key] = value
      end
    rescue
      # ignore if no buildoptions exists
    end
  end

  def private_key_path
    Dice.config.ssh_private_key
  end

  def port
    port = "22"
    port
  end

  def host
    Dice.config.buildhost
  end

  def user
    Dice.config.ssh_user
  end

  private

  def semaphore_id
    @semaphore_id ||= get_semaphore
  end

  def semaphore
    @semaphore ||= Semaphore.new
  end

  def get_semaphore
    id = semaphore.semget(get_lock_key)
    if (id < 0)
      raise Dice::Errors::SemaphoreSemGetFailed.new(
        "Can't create semaphore: semget returned #{id}"
      )
    end
    id
  end

  def get_lock_key
    encoded_path = Digest::SHA256.bubblebabble(lock)
    # for creating a named IPC semaphore we need an integer key
    # value representing the lock file path. The value is build
    # from the sum of the ascii codes of the SHA256 encoded
    # lock path value. This is not 100% safe because the sum
    # could be the same for different encoded results. If one
    # has a better idea feel free to fix :-)
    encoded_path.sum
  end
end
