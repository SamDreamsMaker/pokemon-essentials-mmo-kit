#===============================================================================
# PEMK :: AuthUI  (client side)
#-------------------------------------------------------------------------------
# The in-game login / registration screen shown at the load crossroads when there
# is no valid session token AND no credentials in mmo_config.txt. Accounts are
# identified by EMAIL (email + password); the in-game display name is the
# character's own name (chosen in the intro), not a separate handle.
#
# Built on Essentials' own message + free-text widgets (pbMessageFreeText masks
# the password), so it works at the load screen like its New Game / Continue menu.
# mmo_config.txt credentials remain a dev shortcut that skips this screen.
#===============================================================================
module PEMK
  module AuthUI
    module_function

    # Returns true if authenticated (Auth.apply_login ran), false if the player
    # chose to play offline.
    def run(c)
      PEMK.log("auth: showing in-game login/register screen")
      loop do
        choice = pbMessage(_INTL("Connect to the game server."),
                           [_INTL("Log in"), _INTL("Create account"), _INTL("Play offline")], 3)
        case choice
        when 0 then return true if login(c)
        when 1 then return true if register(c)
        else
          PEMK.log("auth: player chose offline")
          return false
        end
      end
    end

    def login(c)
      email = ask(_INTL("Enter your email:"), false, 100)
      return false if email.empty?

      pw = ask(_INTL("Enter your password:"), true, 64)
      return false if pw.empty?

      reply = PEMK::Auth.send_and_wait(c, { :type => :login, :email => email, :password => pw },
                                       [:login_ok, :login_err])
      return true if apply(reply, :login_ok)

      pbMessage(_INTL("Login failed: {1}.", friendly(reply)))
      false
    end

    def register(c)
      email = ask(_INTL("Enter your email (this is your login):"), false, 100)
      return false if email.empty?

      pw = ask(_INTL("Choose a password (at least 8 characters):"), true, 64)
      return false if pw.empty?

      if ask(_INTL("Confirm your password:"), true, 64) != pw
        pbMessage(_INTL("The passwords did not match."))
        return false
      end

      reg = PEMK::Auth.send_and_wait(c, { :type => :register, :email => email, :password => pw },
                                     [:register_ok, :register_err])
      unless reg && reg[:type] == :register_ok
        pbMessage(_INTL("Could not create the account: {1}.", friendly(reg)))
        return false
      end

      reply = PEMK::Auth.send_and_wait(c, { :type => :login, :email => email, :password => pw },
                                       [:login_ok, :login_err])
      if apply(reply, :login_ok)
        pbMessage(_INTL("Your account is ready. Welcome!"))
        return true
      end
      pbMessage(_INTL("Account created, but automatic login failed — pick \"Log in\"."))
      false
    end

    def apply(reply, ok_type)
      return false unless reply && reply[:type] == ok_type

      PEMK::Auth.apply_login(reply)
      true
    end

    # Free-text prompt (password-masked when +hidden+). Returns a stripped string.
    def ask(prompt, hidden, maxlen)
      (pbMessageFreeText(prompt, "", hidden, maxlen) || "").strip
    end

    def friendly(reply)
      case reply && reply[:reason]
      when "not_found"     then _INTL("no account with that email")
      when "bad_password"  then _INTL("wrong password")
      when "locked"        then _INTL("too many attempts, try again later")
      when "rate_limited"  then _INTL("too many attempts, wait a moment")
      when "taken"         then _INTL("that email is already registered")
      when "invalid_email" then _INTL("that email looks invalid")
      when "weak_password" then _INTL("password needs at least 8 characters")
      when nil             then _INTL("no response from the server")
      else (reply[:reason]).to_s
      end
    end
  end
end
