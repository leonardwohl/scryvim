local types = require('scryvim.types')

describe('types', function()
  it('picks the highest-priority card type', function()
    local function of(type_line)
      return types.of({ type_line = type_line })
    end
    assert.are.equal('instant', of('Instant'))
    assert.are.equal('creature', of('Legendary Artifact Creature — Equipment Golem'))
    assert.are.equal('land', of('Land Creature — Forest Dryad'))
    assert.are.equal('land', of('Artifact Land'))
    assert.are.equal('artifact', of('Enchantment Artifact'))
    assert.are.equal('enchantment', of('Kindred Enchantment — Elf'))
    assert.are.equal('planeswalker', of('Legendary Planeswalker — Jace'))
    assert.are.equal('sorcery', of('Kindred Sorcery — Goblin'))
    -- Subtypes don't count.
    assert.are.equal('creature', of('Creature — Land Elemental'))
    assert.is_nil(of('Emblem — Jace'))
    assert.is_nil(of(''))
  end)

  it('uses the front face of multi-face cards', function()
    assert.are.equal(
      'battle',
      types.of({
        type_line = 'Battle — Siege // Creature — Elemental',
        card_faces = { { type_line = 'Battle — Siege' }, { type_line = 'Creature — Elemental' } },
      })
    )
    assert.are.equal('sorcery', types.of({ type_line = 'Sorcery // Land' }))
  end)

  it('links each type to a colorscheme group by default', function()
    vim.api.nvim_set_hl(0, '@lsp.type.land.deck', { fg = '#123456' })
    types.setup_highlights()
    assert.are.equal(tonumber('123456', 16), vim.api.nvim_get_hl(0, { name = '@lsp.type.land.deck' }).fg)
    assert.are.equal('Type', vim.api.nvim_get_hl(0, { name = '@lsp.type.creature.deck' }).link)
    for _, t in ipairs(types.TYPES) do
      assert.is_not_nil(types.LINKS[t])
    end
  end)
end)
