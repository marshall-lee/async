# Copyright, 2017, by Samuel G. D. Williams. <http://www.codeotaku.com>
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

require 'fiber'
require 'forwardable'

require_relative 'node'
require_relative 'condition'

module Async
	# Raised when a task is explicitly stopped.
	class Interrupt < Exception
	end

	# A task represents the state associated with the execution of an asynchronous
	# block.
	class Task < Node
		extend Forwardable
	
		# Yield the unerlying `result` for the task. If the result
		# is an Exception, then that result will be raised an its
		# exception.
		# @return [Object] result of the task
		# @raise [Exception] if the result is an exception
		# @yield [result] result of the task if a block if given.
		def self.yield
			if block_given?
				result = yield
			else
				result = Fiber.yield
			end
			
			if result.is_a? Exception
				raise result
			else
				return result
			end
		end
	
		# Create a new task.
		# @param ios [Array] an array of `IO` objects such as `TCPServer`, `Socket`, etc.
		# @param reactor [Async::Reactor] 
		# @return [void]
		def initialize(ios, reactor)
			if parent = Task.current?
				super(parent)
			else
				super(reactor)
			end
			
			@ios = Hash[
				ios.collect{|io| [io.fileno, reactor.wrap(io, self)]}
			]
			
			@reactor = reactor
			
			@status = :running
			@result = nil
			
			@condition = nil
			
			@fiber = Fiber.new do
				set!
				
				begin
					@result = yield(*@ios.values, self)
					@status = :complete
					# Async.logger.debug("Task #{self} completed normally.")
				rescue Interrupt
					@status = :interrupted
					# Async.logger.debug("Task #{self} interrupted: #{$!}")
				rescue Exception => error
					@result = error
					@status = :failed
					# Async.logger.debug("Task #{self} failed: #{$!}")
					raise
				ensure
					# Async.logger.debug("Task #{self} closing: #{$!}")
					close
				end
			end
		end
		
		# Show the current status of the task as a string.
		# @todo (picat) Add test for this method?	
		def to_s
			"#{super}[#{@status}]"
		end
	
		# @attr ios [Array<IO>] All wrappers associated with this task.
		attr :ios
		
		# @attr ios [Reactor] The reactor the task was created within.
		attr :reactor
		def_delegators :@reactor, :timeout, :sleep
		
		# @attr fiber [Fiber] The fiber which is being used for the execution of this task.
		attr :fiber
		def_delegators :@fiber, :alive?
		
		# @attr status [Symbol] The status of the execution of the fiber, one of `:running`, `:complete`, `:interrupted`, or `:failed`.
		attr :status
		
		# Resume the execution of the task.
		def run
			@fiber.resume
		end
	
		# Retrieve the current result of the task. Will cause the caller to wait until result is available.
		# @raise [RuntimeError] if the task's fiber is the current fiber.
		# @return [Object]
		def result
			raise RuntimeError.new("Cannot wait on own fiber") if Fiber.current.equal?(@fiber)
			
			if running?
				@condition ||= Condition.new
				@condition.wait
			else
				Task.yield {@result}
			end
		end
		
		alias wait result
	
		# Stop the task and all of its children.
		# @return [void]
		def stop
			@children.each(&:stop)
			
			if @fiber.alive?
				exception = Interrupt.new("Stop right now!")
				@fiber.resume(exception)
			end
		end
	
		# Provide a wrapper to an IO object with a Reactor.
		# @yield [Async::Wrapper] a wrapped object.
		def with(io, *args)
			wrapper = @reactor.wrap(io, self)
			yield wrapper, *args
		ensure
			wrapper.close if wrapper
			io.close if io
		end
		
		# Wrap and bind the given object to the reactor.
		# @param io the native object to bind to this task.
		# @return [Wrapper] The wrapped object.
		def bind(io)
			@ios[io.fileno] ||= @reactor.wrap(io, self)
		end
		
		# Register a given IO with given interests to be able to monitor it.
		# @param io [IO] a native io object.
		# @param interests [Symbol] One of `:r`, `:w` or `:rw`.
		# @return [NIO::Monitor]
		def register(io, interests)
			@reactor.register(io, interests)
		end
	
		# Lookup the {Task} for the current fiber. Raise `RuntimeError` if none is available.
		# @return [Async::Task]
		# @raise [RuntimeError] if task was not {set!} for the current fiber.
		def self.current
			Thread.current[:async_task] or raise RuntimeError, "No async task available!"
		end

			
		# Check if there is a task defined for the current fiber.
		# @return [Async::Task, nil]
		def self.current?
			Thread.current[:async_task]
		end
	
		# Check if the task is running.
		# @return [Boolean]
		def running?
			@status == :running
		end
		
		# Whether we can remove this node from the reactor graph.
		# @return [Boolean]
		def finished?
			super && @status != :running
		end
		
		# Close all bound IO objects.
		def close
			@ios.each_value(&:close)
			@ios = nil
			
			# Attempt to remove this node from the task tree.
			consume
			
			# If this task was being used as a future, signal completion here:
			if @condition
				@condition.signal(@result)
			end
		end
		
		private
		
		# Set the current fiber's `:async_task` to this task.
		def set!
			# This is actually fiber-local:
			Thread.current[:async_task] = self
		end
	end
end
