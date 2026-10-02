require "minitest/autorun"

# docs/SERVER-SETTINGS.md names every setting the server and its tools read from the
# environment, and nothing they do not: a setting added to config.rb or a bin/ tool with
# no row there fails here, and so does a row no code reads any more.
class SettingsDocTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  DOC  = File.join(ROOT, "docs", "SERVER-SETTINGS.md")
  NAME = /(PEMK_[A-Z_]+|REPLAY_[A-Z_]+|DATABASE_URL)/

  def read_by_the_code
    names = File.read(File.join(ROOT, "server", "lib", "pemk", "config.rb")).scan(/env\.fetch\("#{NAME}"/)
    Dir[File.join(ROOT, "server", "bin", "*.rb")].each do |tool|
      names += File.read(tool).scan(/ENV(?:\[|\.fetch\()"#{NAME}"/)
    end
    names.flatten.uniq.sort
  end

  def rows
    File.read(DOC).scan(/^\| `#{NAME}` \|/).flatten
  end

  def test_every_setting_the_code_reads_has_its_row
    assert_empty read_by_the_code - rows, "settings the code reads with no row in docs/SERVER-SETTINGS.md"
  end

  def test_every_row_is_a_setting_the_code_reads
    assert_empty rows - read_by_the_code, "rows in docs/SERVER-SETTINGS.md no code reads"
    assert_equal rows.uniq, rows, "one row per setting"
  end

  # The defaults the page states for the tri-state settings are the code's.
  def test_a_tristate_setting_is_documented_off_by_default
    tristate = File.read(File.join(ROOT, "server", "lib", "pemk", "config.rb"))
                   .scan(/env\.fetch\("(PEMK_[A-Z_]+)", "off"\)/).flatten
    refute_empty tristate
    doc = File.read(DOC)
    tristate.each do |name|
      assert_match(/^\| `#{name}` \| `off` \|/, doc, "#{name} defaults to off")
    end
  end
end
