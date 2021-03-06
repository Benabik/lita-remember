module Lita
  module Handlers
    class Remember < Handler
      route(
        /^what(?!\s+do\s+you\s+remember(\s*\?)?\s*$)('s|\s+(is|are))?(\s+(a|the))?\s+(?<term>.*?)\s*(\?\s*)?$/i,
        :lookup,
        command: true,
        help: {
          t('help.what.syntax') => t('help.what.desc')
        }
      )

      route(
        /^what('s|\s+(is|are))?(\s+(a|the))?\s+(?<term>.*?)\s*(\?\s*)?$/i,
        :lookup_quiet,
        command: false,
      )

      route(
        /^show\s+me\s+(?!list\s*$)((a|the)\s+)?(?<term>.*?)\s*(\.\s*)?$/i,
        :lookup,
        command: true,
        help: {
          'show me <term>' => t('help.what.desc')
        }
      )

      route(
        /^show\s+me\s+(?!list\s*$)((a|the)\s+)?(?<term>.*?)\s*(\.\s*)?$/i,
        :lookup_quiet,
        command: false,
      )

      route(
        /\bshow\s+me\s+list\b/i,
        :all_the_terms
      )

      route(
        /^who\s+added\s+(?<term>.*?)\s*(\?\s*)?$/i,
        :info,
        command: true,
        help: {
          t('help.info.syntax') => t('help.info.desc')
        }
      )

      route(
        /^remember(\s+(a|the))?\s+(?<term>.+?)\s+(is|are)\s+(?<definition>.+?)\s*$/i,
        :remember,
        command: true,
        help: {
          t('help.remember.syntax') => t('help.remember.desc')
        }
      )

      route(
        /^((a|the)\s+)?(?<term1>.+?)\s+(is|are)\s+also(\s+(a|the))?\s+(?<term2>.+?)\s*$/i,
        :synonym,
        command: true,
        help: {
          t('help.synonym.syntax') => t('help.synonym.desc')
        }
      )

      route(
        /^forget(\s+about)?\s+(?<term>.+?)\s*$/i,
        :forget,
        command: true,
        restrict_to: [:admins, :remember_admins],
        help: {
          t('help.forget.syntax') => t('help.forget.desc')
        }
      )

      route(
        /^what\s+do\s+you\s+remember\s*(\?\s*)?$/i,
        :all_the_terms,
        command: true,
        help: {
          t('help.all.syntax') => t('help.all.desc')
        }
      )

      route(
        /^search\s+(?<type>(terms|definitions))\s+for\s+(?<query>.*?)\s*$/i,
        :search,
        command: true,
        help: {
          t('help.search.syntax') => t('help.search.desc')
        }
      )

      def lookup(response)
        term = response.match_data['term']
        record = definition term
        return response.reply(t('response.unknown', term: term)) unless record
        response.reply format_definition(term, record)
      end

      def lookup_quiet(response)
        return if response.message.command?
        term = response.match_data['term']
        record = definition term
        response.reply format_definition(term, record) if record
      end

      def info(response)
        term = response.match_data['term']
        record = definition term, false
        return response.reply(t('response.unknown', term: term)) unless record
        response.reply format_info(term, record)
      end

      def forget(response)
        term = response.match_data['term']
        if known? term
          delete(term)
          response.reply(format_deletion(term))
        else
          response.reply format_delete_unknown(term)
        end
      end

      def remember(response)
        term = response.match_data['term']
        info = response.match_data['definition']
        record = definition term, false
        if record and not is_admin?(response.user)
          response.reply format_known(term, record)
        else
          write(term, info, response.user.id)
          response.reply(format_confirmation(term, definition(term, false)))
        end
      end

      def synonym(response)
        term1 = response.match_data['term1']
        term2 = response.match_data['term2']

        if known? term1
          return response.reply(format_syn_known(term1, term2)) if known? term2
          new, original = term2, term1
        elsif known? term2
          new, original = term1, term2
        else
          return response.reply format_syn_unknown(term2, term2)
        end

        write_syn new, original, response.user.id
        response.reply format_synonym(new, original)
      end

      def search(response)
        type  = response.match_data['type']
        query = response.match_data['query'].downcase
        matching_terms = []
        if type == 'terms'
          terms = fetch_all_terms
          matching_terms = terms.select { |term| term.include?(query) }
        else
          fetch_all.each { |term,definition|
            matching_terms.push(term) if definition.downcase.include?(query)
          }
        end
        if matching_terms.empty?
          response.reply(t('response.empty_search_result', type: type))
        else
          matching_terms.sort!
          reply = matching_terms.join "\n - "

          if matching_terms.length > 5 and not response.message.private_message?
            response.reply t('response.long_reply', count: matching_terms.length)
            response.reply_privately format_search(reply)
          else
            response.reply format_search(reply)
          end
        end
      end

      def all_the_terms(response)
        terms = fetch_all_terms
        count = terms.length
        if count < 24 or response.message.private_message?
          response.reply format_all_the_terms terms
        else
          terms.delete_if { |t| redis.hexists t, 'synonym' }
          terms.sort_by! { |t| -redis.hget(t, 'hits').to_i }
          terms = terms.take 24
          response.reply format_too_many(terms, count)
        end
      end

      def fetch_all()
        results = {}
        redis.scan_each(:count => 1000) { |term|
          definition = redis.hget term, 'definition'
          results[term] = definition unless definition.nil?
        }
        return results
      end

      def fetch_all_terms()
        terms = []
        redis.scan_each(:count => 1000) { |term| terms << term }
        return terms
      end

      private

      def format_all_the_terms(terms)
        terms.sort!
        t('response.all', terms: terms.join("\n - "))
      end

      def format_too_many(terms, count)
        t('response.too_many', terms: terms.join(', '), count: count)
      end

      def format_search(terms)
        t('response.search', terms: terms)
      end

      def format_deletion(term)
        t('response.forget', term: term)
      end

      def format_delete_unknown(term)
        t('response.forget_nothing', term: term)
      end

      def format_confirmation(term, definition)
        t('response.confirm', term: term, definition: definition[:definition])
      end

      def format_definition(term, definition)
        t('response.is', term: term, definition: definition[:definition])
      end

      def format_info(term, definition)
        username = Lita::User.find_by_id(definition[:userid]).mention_name
        if definition[:term] != term
          t 'response.info_syn', term: term, synonym: definition[:term],
            count: definition[:hits], user: username
        else
          t'response.info', term: term, definition: definition[:definition],
            count: definition[:hits], user: username
        end
      end

      def format_synonym(new, original)
        t 'response.synonym', new: new, original: original
      end

      def format_syn_known(term1, term2)
        t 'response.syn_known', term1: term1, term2: term2
      end

      def format_syn_unknown(term1, term2)
        t 'response.syn_unknown', term1: term1, term2: term2
      end

      def format_known(term, definition)
        t('response.already_know', term: term, definition: definition[:term])
      end

      def known?(term)
        redis.exists(term.downcase)
      end

      def definition(term, hit = true)
        term = term.downcase

        return nil unless known? term

        redis.hincrby term, 'hits', 1 if hit

        result = redis.hmget term, 'hits', 'userid'
        record = {
          :hits   => result[0],
          :userid => result[1],
        }

        synonyms = []
        orig = term
        until (synonym = redis.hget term, 'synonym').nil?
          synonyms << term
          term = synonym
        end
        record[:term] = term
        redis.hincrby term, 'hits', 1 if hit and term != orig

        record[:definition] = redis.hget term, 'definition'
        unless record[:definition]
          synonyms.each {|syn| delete syn}
          return nil
        end

        record
      end

      def delete(term)
        redis.del(term.downcase)
      end

      def write(term, definition, userid)
        redis.hset(term.downcase, 'definition', definition)
        redis.hset(term.downcase, 'userid', userid)
        redis.hset(term.downcase, 'hits', 0)
      end

      def write_syn(new, original, userid)
        new = new.downcase
        original = original.downcase
        redis.hset new, 'synonym', original
        redis.hset new, 'userid', userid
        redis.hset new, 'hits', 0
      end

      def is_admin?(user)
        a = robot.auth
        a.user_is_admin?(user) or a.user_in_group?(user, :remember_admins)
      end
    end
    Lita.register_handler(Remember)
  end
end
