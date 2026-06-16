import { useState } from 'react'

import { useSessionActions } from '../hooks/useSession'
import type {
  FollowupComposerProps,
  FollowupSubmitInput,
} from './types/prompt'

export function FollowupComposer({
  followupRequest,
  onSubmit,
}: FollowupComposerProps) {
  const [followupText, setFollowupText] = useState('')
  const [selectedOptionIds, setSelectedOptionIds] = useState<string[]>([])
  const { submitFollowup } = useSessionActions()
  const handleSubmit = (input: FollowupSubmitInput) => {
    const action = onSubmit ?? submitFollowup
    void action(input)
  }

  const canContinue =
    followupRequest.kind === 'text'
      ? followupText.trim().length > 0
      : selectedOptionIds.length > 0

  function toggleFollowupOption(optionId: string) {
    if (followupRequest.kind === 'single') {
      setSelectedOptionIds([optionId])
      return
    }

    setSelectedOptionIds((current) =>
      current.includes(optionId)
        ? current.filter((id) => id !== optionId)
        : [...current, optionId],
    )
  }

  return (
    <section className="mx-auto w-full max-w-3xl rounded-3xl border border-border bg-card px-4 pb-3.5 pt-4 shadow-xl shadow-foreground/5 backdrop-blur-lg dark:border-white/10 dark:shadow-black/20">
      <p className="mb-2.5 select-text text-xs uppercase tracking-widest text-muted-foreground">
        Follow-up
      </p>
      <h2 className="select-text text-base font-semibold leading-6 text-foreground">
        {followupRequest.question}
      </h2>

      {followupRequest.kind === 'text' ? (
        <textarea
          className="mt-4 min-h-28 w-full resize-none rounded-2xl border border-border bg-secondary p-3.5 text-base leading-6 text-foreground outline-none placeholder:text-muted-foreground dark:border-white/10"
          aria-label="Follow-up response"
          value={followupText}
          onChange={(event) => setFollowupText(event.target.value)}
          rows={4}
        />
      ) : (
        <div className="mt-4 grid gap-2.5">
          {followupRequest.options?.map((option) => {
            const checked = selectedOptionIds.includes(option.id)
            return (
              <label
                key={option.id}
                className="flex items-center gap-2.5 rounded-2xl border border-border bg-secondary px-3.5 py-3 text-sm text-foreground dark:border-white/10"
              >
                <input
                  type={followupRequest.kind === 'single' ? 'radio' : 'checkbox'}
                  name={`followup-option-${followupRequest.followupId}`}
                  checked={checked}
                  onChange={() => toggleFollowupOption(option.id)}
                />
                <span>{option.label}</span>
              </label>
            )
          })}
        </div>
      )}

      <div className="mt-4 flex items-center justify-between gap-4">
        <button
          type="button"
          className="appearance-none font-inherit transition duration-150 ease-out disabled:cursor-not-allowed disabled:opacity-45 rounded-full border border-border bg-card px-4 py-2.5 text-sm text-foreground dark:border-white/10"
          onClick={() => handleSubmit({ cancelled: true })}
        >
          Cancel
        </button>
        <button
          type="button"
          className="appearance-none font-inherit transition duration-150 ease-out disabled:cursor-not-allowed disabled:opacity-45 rounded-full bg-primary px-4 py-2.5 text-sm font-semibold text-primary-foreground"
          onClick={() =>
            handleSubmit({
              cancelled: false,
              text: followupText,
              selectedOptionIds,
            })
          }
          disabled={!canContinue}
        >
          Continue
        </button>
      </div>
    </section>
  )
}
