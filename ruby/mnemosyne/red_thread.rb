# frozen_string_literal: true

class Mnemosyne
  # RedThread — the golden thread that unites sessions into one flow.
  #
  # The Aegis is the *what* (the course); Hydra is the *who* (the heads);
  # the RedThread is the *continuity between them*: a compact briefing any new
  # prompt inhales so it knows not only "who am I / where am I" but "who was
  # here before me and what were they doing". Deterministic and flash-free —
  # the sibling roster + open sub-goals are read straight from the substrate,
  # so there is no pre-turn latency.
  #
  # Correspondence, not duplication: it re-reads the same rows Coniunctio
  # already surfaces for live flows (Hydra.summary_line) but widens the lens
  # to *recently silent/closed* sessions and the open AethernautManifest —
  # the two things a fresh session otherwise never sees. A new head therefore
  # picks up the thread without the practitioner having to re-explain what was
  # being worked on.
  class RedThread
    class << self
      def briefing(project: nil, exclude: nil, session_limit: 6, goal_limit: 5, max_aegis: 100)
        blocks = []
        sessions = Hydra.thread_block(project: project, exclude: exclude,
                                      limit: session_limit, max_aegis: max_aegis)
        blocks << sessions if sessions && !sessions.empty?
        goals = AethernautManifest.thread_block(limit: goal_limit)
        blocks << goals if goals && !goals.empty?
        return nil if blocks.empty?

        "RED THREAD (cross-session continuity):\n" + blocks.join("\n\n")
      end
    end
  end
end
