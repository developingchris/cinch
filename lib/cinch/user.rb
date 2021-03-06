# -*- coding: utf-8 -*-
require "cinch/target"

module Cinch
  # @attr_reader [String] user
  # @attr_reader [String] host
  # @attr_reader [String] realname
  # @attr_reader [String] authname
  # @attr_reader [Number] idle How long this user has been idle, in seconds.
  #   This is a snapshot of the last WHOIS.
  # @attr_reader [Time] signed_on_at
  # @attr_reader [Array<Channel>] channels All channels the user is in.
  class User < Target
    include Syncable

    @users = {} # this will be removed with version 2.0.0
    class << self

      # @overload find_ensured(nick, bot)
      #   Finds or creates a user based on his nick.
      #
      #   @param [String] nick The user's nickname
      #   @param [Bot]    bot  An instance of Bot
      # @overload find_ensured(user, nick, host, bot)
      #   Finds or creates a user based on his nick but already
      #   setting user and host.
      #
      #   @param [String] user The username
      #   @param [String] nick The nickname
      #   @param [String] host The user's hostname
      #   @param [Bot]    bot  An instance of bot
      #
      # @return [User]
      # @deprecated See {Bot#user_manager} and {UserManager#find_ensured} instead
      # @note This method does not work properly if running more than one bot
      # @note This method will be removed in Cinch 2.0.0
      def find_ensured(*args)
        Cinch.print_deprecation("1.1.0", "User.find_ensured")

        case args.size
        when 2
          nick = args.first
          bot  = args.last
          bargs = [nick]
        when 4
          nick = args[1]
          bot  = args.pop
          bargs = args
        else
          raise ArgumentError
        end
        downcased_nick = nick.irc_downcase(bot.irc.isupport["CASEMAPPING"])
        @users[downcased_nick] = args.last.user_manager.find_ensured(*args[0..-2])
        # note: the complete case statement and the assignment to
        #   @users is only for keeping compatibility with older
        #   versions, which still use User.find and User.all.
      end

      # Finds a user.
      #
      # @param [String] nick nick of a user
      # @return [User, nil]
      # @deprecated See {Bot#user_manager} and {UserManager#find} instead
      # @note This method does not work properly if running more than one bot
      # @note This method will be removed in Cinch 2.0.0
      def find(nick)
        Cinch.print_deprecation("1.1.0", "User.find")

        @users[downcased_nick]
      end

      # @return [Array<User>] Returns all users
      # @deprecated See {Bot#user_manager} and {CacheManager#each} instead
      # @note This method does not work properly if running more than one bot
      # @note This method will be removed in Cinch 2.0.0
      def all
        Cinch.print_deprecation("1.1.0", "User.all")

        @users.values
      end
    end

    alias_method :nick, :name
    # @return [String]
    attr_reader :last_nick
    # @return [Boolean]
    attr_reader :synced
    # @return [Boolean]
    attr_reader :in_whois
    # @api private
    attr_writer :in_whois

    # @return [Boolean] True if the instance references an user who
    #   cannot be found on the server.
    attr_reader :unknown
    alias_method :unknown?, :unknown
    undef_method "unknown?"
    undef_method "unknown"
    def unknown
      self.unknown?
    end

    # @return [Boolean] True if the user is using a secure connection, i.e. SSL.
    attr_reader :secure
    alias_method :secure?, :secure
    undef_method "secure?"
    undef_method "secure"
    def secure
      self.secure?
    end

    # By default, you can use methods like User#user, User#host and
    # alike – If you however fear that another thread might change
    # data while you're using it and if this means a critical issue to
    # your code, you can store a clone of the result of this method
    # and work with that instead.
    #
    # @example
    #   on :channel do |m|
    #     data = m.user.data.dup
    #     do_something_with(data.user)
    #     do_something_with(data.host)
    #   end
    # @return [Hash]
    attr_reader :data
    def initialize(*args)
      @data = {
        :user         => nil,
        :host         => nil,
        :realname     => nil,
        :authname     => nil,
        :idle         => 0,
        :signed_on_at => nil,
        :unknown?     => false,
        :channels     => [],
        :secure?      => false,
      }
      case args.size
      when 2
        @name, @bot = args
      when 4
        @data[:user], @name, @data[:host], @bot = args
      else
        raise ArgumentError
      end

      @synced_attributes  = Set.new

      @when_requesting_synced_attribute = lambda {|attr|
        unless @synced
          @data[:unknown?] = false
          unsync :unknown?

          unsync attr
          whois
        end
      }
    end

    # Checks if the user is identified. Currently officially supports
    # Quakenet and Freenode.
    #
    # @return [Boolean] true if the user is identified
    def authed?
      !attr(:authname).nil?
    end

    # @see Syncable#attr
    def attr(attribute, data = true, unsync = false)
      super
    end

    # Queries the IRC server for information on the user. This will
    # set the User's state to not synced. After all information are
    # received, the object will be set back to synced.
    #
    # @return [void]
    def whois
      return if @in_whois
      @synced = false
      @data.keys.each do |attr|
        unsync attr
      end

      @in_whois = true
      if @bot.irc.network == "jtv"
        # the justin tv "IRC" network does not support WHOIS with two
        # arguments
        @bot.raw "WHOIS #@name"
      else
        @bot.raw "WHOIS #@name #@name"
      end
    end
    alias_method :refresh, :whois

    # @param [Hash, nil] values A hash of values gathered from WHOIS,
    #   or `nil` if no data was returned
    # @param [Boolean] not_found Has to be true if WHOIS resulted in
    #   an unknown user
    # @return [void]
    # @api private
    # @since 1.0.1
    def end_of_whois(values, not_found = false)
      @in_whois = false
      if not_found
        sync(:unknown?, true, true)
        sync(:idle, 0, true)
        sync(:channels, [], true)

        fields = @data.keys
        fields.delete(:unknown?)
        fields.delete(:idle)
        fields.delete(:channels)
        fields.each do |field|
          sync(field, nil, true)
        end

        return
      end

      if values.nil?
        # for some reason, we did not receive user information. one
        # reason is freenode throttling WHOIS
        Thread.new do
          sleep 2
          whois
        end
        return
      end

      {
        :authname => nil,
        :idle => 0,
        :secure? => false,
      }.merge(values).each do |attr, value|
        sync(attr, value, true)
      end

      sync(:unknown?, false, true)
      @synced = true
    end

    # @return [void]
    # @since 1.0.1
    # @api private
    # @see Syncable#unsync_all
    def unsync_all
      @synced = false
      super
    end

    # @return [String]
    def to_s
      @name
    end

    # @return [String]
    def inspect
      "#<User nick=#{@name.inspect}>"
    end

    # Generates a mask for the user.
    #
    # @param [String] s a pattern for generating the mask.
    #
    #     - %n = nickname
    #     - %u = username
    #     - %h = host
    #     - %r = realname
    #     - %a = authname
    #
    # @return [Mask]
    def mask(s = "%n!%u@%h")
      s = s.gsub(/%(.)/) {
        case $1
        when "n"
          @name
        when "u"
          self.user
        when "h"
          self.host
        when "r"
          self.realname
        when "a"
          self.authname
        end
      }

      Mask.new(s)
    end

    # Check if the user matches a mask.
    #
    # @param [Ban, Mask, User, String] other The user or mask to match against
    # @return [Boolean]
    def match(other)
      Mask.from(other) =~ Mask.from(self)
    end
    alias_method :=~, :match

    # @api private
    def update_nick(new_nick)
      @last_nick, @name = @name, new_nick
      @bot.user_manager.update_nick(self)
    end

    # Provides synced access to user attributes.
    def method_missing(m, *args)
      if m.to_s =~ /^(.+)_unsynced$/
        m = $1.to_sym
        unsync = true
      end

      if @data.has_key?(m)
        attr(m, true, unsync = false)
      else
        super
      end
    end

    def respond_to?(m)
      if m.to_s =~ /^(.+)_unsynced$/
        m = $1.to_sym
      end

      return @data.has_key?(m) || super
    end

    # @return [Boolean]
    def ==(other)
      return case other
             when self.class
               @name == other.nick
             when String
               self.to_s == other
             when Bot
               self.nick == other.config.nick
             else
               false
             end
    end
    alias_method :eql?, "=="
  end
end
