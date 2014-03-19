require 'spec_helper'

describe 'cli: errand', type: :integration do
  context 'when errand is deployed and run multiple times in a deployment' do
    with_reset_sandbox_before_all

    before(:all) do
      manifest_hash = Bosh::Spec::Deployments.simple_manifest

      # Include other jobs in the deployment
      manifest_hash['resource_pools'].first['size'] = 3
      manifest_hash['jobs'].first['instances'] = 1

      # First errand
      manifest_hash['jobs'] << {
        'name'          => 'errand1-name',
        'template'      => 'errand1',
        'lifecycle'     => 'errand',
        'resource_pool' => 'a',
        'instances'     => 1,
        'networks'      => [{ 'name' => 'a' }],
        'properties' => {
          'errand1' => {
            'exit_code' => 0,
            'stdout'    => 'some-errand1-stdout',
            'stderr'    => 'some-errand1-stderr',
            'run_package_file' => true,
          },
        },
      }

      # Second errand
      manifest_hash['jobs'] << {
        'name'          => 'errand2-name',
        'template'      => 'errand1',
        'lifecycle'     => 'errand',
        'resource_pool' => 'a',
        'instances'     => 2, # takes up remaining available resource in the pool
        'networks'      => [{ 'name' => 'a' }],
        'properties' => {
          'errand1' => {
            'exit_code' => 0,
            'stdout'    => 'some-errand2-stdout',
            'stderr'    => 'some-errand2-stderr',
            'run_package_file' => true,
          },
        },
      }

      deploy_simple(manifest_hash: manifest_hash)
    end

    it 'reallocates and then deallocates errand vms for each errand run' do
      expect_to_have_running_job_indices(%w(
        foobar/0
        unknown/unknown
        unknown/unknown
      ))

      # One 'unknown/unknown' will not show up because
      # run errand does not refill resource pools properly
      output, exit_code = run_bosh('run errand errand1-name', return_exit_code: true)
      expect(output).to include('some-errand1-stdout')
      expect(exit_code).to eq(0)
      expect_to_have_running_job_indices(%w(foobar/0 unknown/unknown))

      output, exit_code = run_bosh('run errand errand2-name', return_exit_code: true)
      expect(output).to include('some-errand2-stdout')
      expect(exit_code).to eq(0)
      expect_to_have_running_job_indices(%w(foobar/0))
    end
  end

  context 'when errand script exits with 0 exit code' do
    with_reset_sandbox_before_all

    before(:all) do
      manifest_hash = Bosh::Spec::Deployments.simple_manifest

      # Include other jobs in the deployment
      manifest_hash['resource_pools'].first['size'] = 2
      manifest_hash['jobs'].first['instances'] = 1

      # Currently errands are represented via jobs
      manifest_hash['jobs'] << {
        'name'          => 'errand1-name',
        'template'      => 'errand1',
        'lifecycle'     => 'errand',
        'resource_pool' => 'a',
        'instances'     => 1,
        'networks'      => [{ 'name' => 'a' }],
        'properties' => {
          'errand1' => {
            'exit_code' => 0,
            'stdout'    => 'some-stdout',
            'stderr'    => 'some-stderr',
            'run_package_file' => true,
          },
        },
      }

      deploy_simple(manifest_hash: manifest_hash)

      @output, @exit_code = run_bosh('run errand errand1-name', return_exit_code: true)
    end

    it 'shows bin/run stdout and stderr' do
      expect(@output).to include('some-stdout')
      expect(@output).to include('some-stderr')
    end

    it 'shows output generated by package script which proves dependent packages are included' do
      expect(@output).to include('stdout-from-errand1-package')
    end

    it 'returns 0 as exit code from the cli and indicates that errand ran successfully' do
      expect(@output).to include('Errand `errand1-name\' completed successfully (exit code 0)')
      expect(@exit_code).to eq(0)
    end
  end

  context 'when errand script exits with non-0 exit code' do
    with_reset_sandbox_before_all

    before(:all) do
      manifest_hash = Bosh::Spec::Deployments.simple_manifest

      # Include other jobs in the deployment
      manifest_hash['resource_pools'].first['size'] = 2
      manifest_hash['jobs'].first['instances'] = 1

      # Currently errands are represented via jobs
      manifest_hash['jobs'] << {
        'name'          => 'errand1-name',
        'template'      => 'errand1',
        'lifecycle'     => 'errand',
        'resource_pool' => 'a',
        'instances'     => 1,
        'networks'      => [{ 'name' => 'a' }],
        'properties' => {
          'errand1' => {
            'exit_code' => 23, # non-0 (and non-1) exit code
            'stdout'    => '', # No output
            'stderr'    => "some-stderr1\nsome-stderr2\nsome-stderr3",
          },
        },
      }

      deploy_simple(manifest_hash: manifest_hash)

      @output, @exit_code = run_bosh('run errand errand1-name', {
        failure_expected: true,
        return_exit_code: true,
      })
    end

    it 'shows errand\'s stdout and stderr' do
      expect(@output).to include("[stdout]\nNone")
      expect(@output).to include("some-stderr1\nsome-stderr2\nsome-stderr3")
    end

    it 'returns 1 as exit code from the cli and indicates that errand completed with error' do
      expect(@output).to include('Errand `errand1-name\' completed with error (exit code 23)')
      expect(@exit_code).to eq(1)
    end
  end

  context 'when errand cannot be run because there is no bin/run found in the job template' do
    with_reset_sandbox_before_all

    before(:all) do
      manifest_hash = Bosh::Spec::Deployments.simple_manifest

      # Mark foobar as an errand even though it does not have bin/run
      manifest_hash['jobs'].first['lifecycle'] = 'errand'

      deploy_simple(manifest_hash: manifest_hash)

      @output, @exit_code = run_bosh('run errand foobar', {
        failure_expected: true,
        return_exit_code: true,
      })
    end

    it 'returns 1 as exit code and mentions absence of bin/run' do
      expect(@output).to include('Error 450001: Job template foobar does not have executable bin/run')
      expect(@output).to include('Errand `foobar\' did not complete')
      expect(@exit_code).to eq(1)
    end
  end

  context 'when errand does not exist' do
    with_reset_sandbox_before_all

    before(:all) do
      deploy_simple

      @output, @exit_code = run_bosh('run errand unknown-errand-name', {
        failure_expected: true,
        return_exit_code: true,
      })
    end

    it 'returns 1 as exit code and mentions not found errand' do
      expect(@output).to include('Errand `unknown-errand-name\' doesn\'t exist')
      expect(@output).to include('Errand `unknown-errand-name\' did not complete')
      expect(@exit_code).to eq(1)
    end
  end

  context 'when deploying with insufficient resources for all errands' do
    with_reset_sandbox_before_each

    it 'returns 1 as exit code and mentions insufficient resources' do
      manifest_hash = Bosh::Spec::Deployments.simple_manifest

      manifest_hash['resource_pools'].first['size'] += 1

      # Errand with sufficient resources
      manifest_hash['jobs'] << {
        'name'          => 'errand1-name',
        'template'      => 'errand1',
        'lifecycle'     => 'errand',
        'resource_pool' => 'a',
        'instances'     => 1,
        'networks'      => [{ 'name' => 'a' }],
        'properties' => {},
      }

      # Errand with insufficient resources
      manifest_hash['jobs'] << {
        'name'          => 'errand2-name',
        'template'      => 'errand1',
        'lifecycle'     => 'errand',
        'resource_pool' => 'a',
        'instances'     => 2,
        'networks'      => [{ 'name' => 'a' }],
        'properties' => {},
      }

      target_and_login
      upload_release
      upload_stemcell
      set_deployment(manifest_hash: manifest_hash)

      output = deploy(failure_expected: true)
      expect($?).not_to be_success
      expect(output).to include("Resource pool `a' is not big enough: 5 VMs needed, capacity is 4")
    end
  end

  def expect_to_have_running_job_indices(job_indicies)
    vms = get_vms
    expect(vms.map { |d| d[:job_index] }).to match_array(job_indicies)
    expect(vms.map { |d| d[:state] }.uniq).to eq(['running'])
  end
end
