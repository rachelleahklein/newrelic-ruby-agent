# encoding: utf-8
# This file is distributed under New Relic's license terms.
# See https://github.com/newrelic/rpm/blob/master/LICENSE for complete details.

# This class is the central point for dispatching get_agent_commands messages
# to the various components that actually process them.
#
# This could be evented further, but we eventually need direct access to things
# like the ThreadProfiler, so it's simpler to just keep it together here.

require 'new_relic/agent/commands/agent_command'
require 'new_relic/agent/commands/xray_session_collection'
require 'new_relic/agent/threading/backtrace_service'

module NewRelic
  module Agent
    module Commands
      class AgentCommandRouter
        attr_reader :handlers, :new_relic_service

        attr_accessor :thread_profiler_session, :backtrace_service,
                      :xray_session_collection

        def initialize(new_relic_service, event_listener=nil)
          @new_relic_service = new_relic_service
          @backtrace_service = Threading::BacktraceService.new(event_listener)

          @thread_profiler_session = ThreadProfilerSession.new(@backtrace_service)
          @xray_session_collection = XraySessionCollection.new(@new_relic_service, @backtrace_service)

          @handlers    = Hash.new { |*| Proc.new { |cmd| self.unrecognized_agent_command(cmd) } }

          @handlers['start_profiler'] = Proc.new { |cmd| thread_profiler_session.handle_start_command(cmd) }
          @handlers['stop_profiler']  = Proc.new { |cmd| thread_profiler_session.handle_stop_command(cmd) }
          @handlers['active_xray_sessions'] = Proc.new { |cmd| xray_session_collection.handle_active_xray_sessions(cmd) }
        end

        def check_for_and_handle_agent_commands
          results = invoke_commands(get_agent_commands)
          new_relic_service.agent_command_results(results) unless results.empty?
        end

        NO_PROFILES_TO_SEND = {}.freeze

        def harvest_data_to_send(disconnecting)
          profiles = []
          profiles += harvest_from_xray_session_collection
          profiles += harvest_from_thread_profiler_session(disconnecting)

          format_harvest_data(profiles)
        end

        def harvest_from_xray_session_collection
          self.xray_session_collection.harvest_thread_profiles
        end

        def harvest_from_thread_profiler_session(disconnecting)
          if disconnecting || self.thread_profiler_session.finished?
            self.thread_profiler_session.stop(true)
            [self.thread_profiler_session.harvest]
          else
            []
          end
        end

        def format_harvest_data(profiles)
          if profiles.empty?
            NO_PROFILES_TO_SEND
          else
            log_profiles(profiles)
            {:profile_data => profiles}
          end
        end

        def log_profiles(profiles)
          profile_descriptors = profiles.map do |p|
            p.xray_id ? "xray_id: #{p.xray_id}" : "profile_id: #{p.profile_id}"
          end
          ::NewRelic::Agent.logger.debug "Sending thread profiles #{profile_descriptors.join(", ")}"
        end

        def get_agent_commands
          commands = new_relic_service.get_agent_commands
          NewRelic::Agent.logger.debug "Received get_agent_commands = #{commands.inspect}"
          commands
        end

        def invoke_commands(collector_commands)
          results = {}

          collector_commands.each do |collector_command|
            agent_command = AgentCommand.new(collector_command)
            results[agent_command.id.to_s] = invoke_command(agent_command)
          end

          results
        end

        class AgentCommandError < StandardError
        end

        def invoke_command(agent_command)
          begin
            call_handler_for(agent_command)
            return success
          rescue AgentCommandError => e
            error(e)
          end
        end

        SUCCESS_RESULT = {}.freeze
        ERROR_KEY = "error"

        def success
          SUCCESS_RESULT
        end

        def error(err)
          { ERROR_KEY => err.message}
        end

        def call_handler_for(agent_command)
          handler = select_handler(agent_command)
          handler.call(agent_command)
        end

        def select_handler(agent_command)
          @handlers[agent_command.name]
        end

        def unrecognized_agent_command(agent_command)
          NewRelic::Agent.logger.debug("Unrecognized agent command #{agent_command.inspect}")
        end
      end
    end
  end
end