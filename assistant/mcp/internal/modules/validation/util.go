package validation

import "strings"

type validationResultInput struct {
	ID string `json:"id"`
}

type whiterabbitInput struct {
	Draft whiterabbitDraft `json:"draft"`
}

type whiterabbitDraft struct {
	Name        string               `json:"name"`
	Kind        string               `json:"kind,omitempty"`
	Description string               `json:"description,omitempty"`
	Commands    []whiterabbitCommand `json:"commands"`
}

type whiterabbitCommand struct {
	Command  string   `json:"command"`
	Args     []string `json:"args"`
	Operator string   `json:"operator,omitempty"`
}

type ansibleInput struct {
	Draft ansibleDraft `json:"draft"`
}

type ansibleDraft struct {
	Name   string `json:"name"`
	Source string `json:"source"`
}

func validateWhiterabbit(input whiterabbitInput) error {
	if strings.TrimSpace(input.Draft.Name) == "" || len(input.Draft.Name) > 200 || len(input.Draft.Kind) > 40 || len(input.Draft.Description) > 4000 || len(input.Draft.Commands) == 0 || len(input.Draft.Commands) > 50 {
		return errInvalid
	}
	for _, command := range input.Draft.Commands {
		if strings.TrimSpace(command.Command) == "" || len(command.Command) > 255 || len(command.Operator) > 4 || len(command.Args) > 200 {
			return errInvalid
		}
		for _, argument := range command.Args {
			if len(argument) > 4096 {
				return errInvalid
			}
		}
	}
	return nil
}

func validateAnsible(input ansibleInput) error {
	if strings.TrimSpace(input.Draft.Name) == "" || len(input.Draft.Name) > 200 || strings.TrimSpace(input.Draft.Source) == "" || len(input.Draft.Source) > 64<<10 {
		return errInvalid
	}
	return nil
}
