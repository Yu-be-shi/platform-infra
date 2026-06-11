variable "name" {
  description = "ネットワーク一式の名前プレフィックス"
  type        = string
}

variable "cidr_block" {
  description = "VPC の CIDR"
  type        = string
  default     = "10.0.0.0/16"
}

variable "tags" {
  type    = map(string)
  default = {}
}
