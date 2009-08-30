#
#  ApplicationController.rb
#  Gmail Notifr
#
#  Created by james on 10/3/08.
#  Copyright (c) 2008 ashchan.com. All rights reserved.
#

require 'osx/cocoa'
require 'yaml'

include OSX
OSX.require_framework 'Security'
OSX.load_bridge_support_file(NSBundle.mainBundle.pathForResource_ofType("Security", "bridgesupport"))
OSX.ruby_thread_switcher_stop

class ApplicationController < OSX::NSObject

	ACCOUNT_MENUITEM_POS = 2

	ib_outlet :preferencesWindow
	ib_outlet :menu
	ib_action :openInbox
	ib_action :checkMailByMenu
	ib_action :showAbout
	ib_action :showPreferencesWindow

		
	def	awakeFromNib
		@status_bar = NSStatusBar.systemStatusBar
		@status_item = @status_bar.statusItemWithLength(NSVariableStatusItemLength)
		@status_item.setHighlightMode(true)
		@status_item.setMenu(@menu)
		
		bundle = NSBundle.mainBundle
		@app_icon = NSImage.alloc.initWithContentsOfFile(bundle.pathForResource_ofType('app', 'tiff'))
		@app_alter_icon = NSImage.alloc.initWithContentsOfFile(bundle.pathForResource_ofType('app_a', 'tiff'))
		@mail_icon = NSImage.alloc.initWithContentsOfFile(bundle.pathForResource_ofType('mail', 'tiff'))
		@mail_alter_icon = NSImage.alloc.initWithContentsOfFile(bundle.pathForResource_ofType('mail_a', 'tiff'))
		@check_icon = NSImage.alloc.initWithContentsOfFile(bundle.pathForResource_ofType('check', 'tiff'))
		@check_alter_icon = NSImage.alloc.initWithContentsOfFile(bundle.pathForResource_ofType('check_a', 'tiff'))
		@error_icon = NSImage.alloc.initWithContentsOfFile(bundle.pathForResource_ofType('error', 'tiff'))
		
		@cached_results = {}
		
		@status_item.setImage(@app_icon)
		@status_item.setAlternateImage(@app_alter_icon)
		
		setupDefaults
		
		@checker_path = NSBundle.mainBundle.pathForAuxiliaryExecutable('gmailchecker')
		
		@growl = GNGrowlController.alloc.init
		@growl.app = self
		setTimer
		checkMail
	end
	
	def	setupDefaults
		GNPreferences::setupDefaults
	end
	
	def	openInbox(sender)
		if sender.title == "Open Inbox"
			# "Open Inbox" menu item
			account = sender.menu.title
		else
			# top menu item for account
			account = sender.title
		end
		# remove the "(number)" part from account name
		openInboxForAccount(account.gsub(/\s\(\d+\)/, ''))
	end
	
	def	openInboxForAccount(account)
		account_domain = account.split("@")
		
		inbox_url = (account_domain.length == 2 && !["gmail.com", "googlemail.com"].include?(account_domain[1])) ? 
			"https://mail.google.com/a/#{account_domain[1]}" : "https://mail.google.com/mail"
		NSWorkspace.sharedWorkspace.openURL(NSURL.URLWithString(inbox_url))
	end
	
	def	checkMail		
		@status_item.setToolTip("checking mail...")
		@status_item.setImage(@check_icon)
		@status_item.setAlternateImage(@check_alter_icon)
				
		@checker.interrupt and @checker = nil if @checker
		@checker = NSTask.alloc.init
		@checker.setCurrentDirectoryPath(@checker_path.stringByDeletingLastPathComponent)
		@checker.setLaunchPath(@checker_path)

		args = NSMutableArray.alloc.init
		GNPreferences.alloc.init.accounts.each do |a|
			args.addObject(a.username.to_s)
			# pass password as base64 encoded to gmailchecker
			args.addObject([a.password.to_s].pack("m"))
		end

		@checker.setArguments(args)		
		
		pipe = NSPipe.alloc.init
		@checker.setStandardOutput(pipe)
		
		nc = NSNotificationCenter.defaultCenter
		fn = pipe.fileHandleForReading
		nc.removeObserver(self)
		nc.addObserver_selector_name_object(self, 'checkCountReturned', NSFileHandleReadToEndOfFileCompletionNotification, fn)
		
		@checker.launch
		fn.readToEndOfFileInBackgroundAndNotify
	end
	
	def	checkCountReturned(notification)
		results = YAML.load(
			NSString.alloc.initWithData_encoding(
				notification.userInfo.valueForKey(NSFileHandleNotificationDataItem),
				NSUTF8StringEncoding
			)
		)
		
		removeAccountMenuItems
		@mail_count = 0
		
		menu_position = ACCOUNT_MENUITEM_POS
		results.each do |k, v|
			addAccountMenuItem(k, v, menu_position)
			menu_position += 1
		end
		
		if @mail_count > 0
			@status_item.setToolTip("#{@mail_count} unread message#{@mail_count == 1 ? '' : 's'}")
			@status_item.setImage(@mail_icon)
			@status_item.setAlternateImage(@mail_alter_icon)
			@status_item.setTitle(@mail_count.to_s)
		else
			@status_item.setToolTip("")
			@status_item.setImage(@app_icon)
			@status_item.setAlternateImage(@app_alter_icon)
			@status_item.setTitle("")
		end
		
		@accounts_count = menu_position - ACCOUNT_MENUITEM_POS
		
		preferences = GNPreferences.alloc.init
		should_notify = false
		
		results.each_key do |account|
			cached_result = @cached_results[account]
			if cached_result[0] != cached_result[1]
				should_notify = true
				@growl.notify(account, cached_result[1]) if preferences.growl	
			end
		end
		
		if should_notify && preferences.sound != GNPreferences::SOUND_NONE && sound = NSSound.soundNamed(preferences.sound)
			sound.play
		end
	end

	def	checkMailByTimer(timer)
		checkMail
	end
	
	def checkMailByMenu
		setTimer
		checkMail
	end
	
	def	showAbout(sender)
		NSApplication.sharedApplication.activateIgnoringOtherApps(true)
		NSApplication.sharedApplication.orderFrontStandardAboutPanel(sender)
	end
	
	def	showPreferencesWindow(sender)	
		NSApplication.sharedApplication.activateIgnoringOtherApps(true)
		@preferencesWindow.makeKeyAndOrderFront(sender)
	end
	
	def	setTimer
		@timer.invalidate if @timer
		@timer = NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats(
			GNPreferences.alloc.init.interval * 60, self, 'checkMailByTimer', nil, true)
	end
	
	def	removeAccountMenuItems
		if @accounts_count
			@accounts_count.times do |t|
				@status_item.menu.removeItemAtIndex(ACCOUNT_MENUITEM_POS)
			end
		end
	end
	
	def	addAccountMenuItem(account_name, results, pos)
		accountMenu = NSMenu.alloc.initWithTitle(account_name)
		
		#open inbox menu item
		openInboxItem = accountMenu.addItemWithTitle_action_keyEquivalent_("Open Inbox", "openInbox", "")
		openInboxItem.target = self
		openInboxItem.enabled = true
		
		accountMenu.addItem(NSMenuItem.separatorItem)
		
		#new messages
		result = results.split("\n")
		mail_count = result.shift
		has_error = false
		
		if mail_count == "E"
			has_error = true
			item = accountMenu.addItemWithTitle_action_keyEquivalent("connection error", nil, "")
		elsif mail_count == "F"
			has_error = true
			item = accountMenu.addItemWithTitle_action_keyEquivalent("username/password wrong", nil, "")
		else
			mail_count = mail_count.to_i
			@mail_count += mail_count.to_i
			tooltip = "#{mail_count} unread message#{mail_count == 1 ? '' : 's'}"
			result.each do |msg|
				accountMenu.addItemWithTitle_action_keyEquivalent_(msg, nil, "")
			end
			
			if mail_count == 0
				force_clear_cache(account_name)
			else
				cache_result(account_name, tooltip + "\n" + result.join("\n"))
			end
		end
		
		#top level menu item for acount
		accountItem = NSMenuItem.alloc.init
		accountItem.title = account_name + " (#{mail_count.to_i})"
		accountItem.submenu = accountMenu
		accountItem.target = self
		accountItem.action = 'openInbox'
		
		if has_error
			accountItem.setImage(@error_icon)
			force_clear_cache(account_name)
		end
		@status_item.menu.insertItem_atIndex(accountItem, pos)
	end
	
	def	cache_result(account, result)
		@cached_results[account] ||= ["", ""]
		@cached_results[account][0] = @cached_results[account][1]
		@cached_results[account][1] = result
	end
	
	def	force_clear_cache(account)
		2.times { cache_result(account, '') }
	end
end
